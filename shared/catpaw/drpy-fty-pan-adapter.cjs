// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';

const PAN_ADAPTERS = Object.freeze([
  'seedhub-v1', 'szps-v1', 'ypanso-v1', 'bpanso-v1', 'kkss-v1', 'uuss-v1'
]);

function installFtyPan() {
  function fail(code) { unsupportedFeature(code || 'drpy_source_unavailable'); }
  function isObj(v) { return Boolean(v) && typeof v === 'object' && !Array.isArray(v); }
  function str(v) { return v === undefined || v === null || v === 'null' ? '' : String(v); }
  function stripHtml(v) {
    return str(v)
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ')
      .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  }
  function hasVodMarkup(t) {
    return /(?:\/voddetail\/|\/vodplay\/|\/vod\/detail\/|module-item|module-search-item|module-card-item|vod-item|"merged_by_type"\s*:|"disk_id"\s*:)/i.test(t);
  }
  function isChallengeBody(body, statusCode) {
    var t = str(body);
    if (!t) return false;
    if (/(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|<title>\s*Just a moment\.\.\.\s*<\/title>|Attention Required!\s*\|\s*Cloudflare|Checking your browser|正在验证您的浏览器|系统安全验证|verify you are human|请完成滑块验证|verifySlider|验证码不正确)/i.test(t)) {
      return true;
    }
    var code = Number(statusCode) || 0;
    var blockedStatus = code === 401 || code === 403 || code === 429 || code === 503;
    if (!blockedStatus && (t.length >= 24000 || hasVodMarkup(t))) return false;
    return /(?:challenges\.cloudflare\.com|cf-turnstile|人机验证)/i.test(t) ||
      /<input[^>]+(?:name|id)=["']?(?:verify|validate|captcha)/i.test(t);
  }
  function checkChallenge(body, statusCode) {
    if (isChallengeBody(body, statusCode)) fail('drpy_verification_required');
  }
  function address(value, base) {
    var v = str(value).trim();
    if (!v || v.length > 8192 || /[\x00-\x20\x7f\\]/.test(v)) fail('drpy_media_protocol');
    if (v.indexOf('//') === 0) v = 'https:' + v;
    var url;
    try { url = joinUrl(base || (cfg.origin + '/'), v); } catch (_) { fail('drpy_media_protocol'); }
    var m = /^(https?):\/\/([^/?#@]+)([^#]*)$/i.exec(url);
    if (!m) fail('drpy_media_protocol');
    return { url: url, origin: m[1].toLowerCase() + '://' + m[2].toLowerCase(), path: m[3] || '/' };
  }
  function safePic(pic, base) {
    var c = str(pic).trim();
    if (!c || /^data:/i.test(c) || /(?:sogoucdn\.com|imagehub\.cc|\/loading\.|\/lazyload\.|\/nopic|\/none\.|\/blank\.|\/default_pic)/i.test(c)) return '';
    if (c.indexOf('//') === 0) c = 'https:' + c;
    try {
      var u = joinUrl(base || (cfg.origin + '/'), c);
      return /^https?:\/\/[^/?#@]+(?:[/?#]|$)/i.test(u) && !/[\x00-\x20\x7f\\]/.test(u) ? u : '';
    } catch (_) { return ''; }
  }
  function utf8ToB64(textVal) {
    return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(str(textVal)));
  }
  function b64ToUtf8(b64Val) {
    var clean = str(b64Val).trim().replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    return CryptoJS.enc.Base64.parse(clean).toString(CryptoJS.enc.Utf8);
  }
  function httpReq(url, opts) {
    var target = address(url).url;
    var res;
    try { res = req(target, Object.assign({ timeout: 9000 }, opts || {})); }
    catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    if (!res || typeof res.content !== 'string') fail('drpy_source_unavailable');
    var body = res.content;
    checkChallenge(body, res.code);
    return { body: body, headers: res.headers || {}, code: res.code || 0 };
  }
  function parseJsonSafe(raw) {
    var t = str(raw).trim();
    if (!t) return null;
    try { return JSON.parse(t); } catch (_) { return null; }
  }
  function isPanShare(u) {
    return /^https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com|cloud\.189\.cn|(?:www\.)?123(?:pan|684|865|912)\.com|115(?:cdn)?\.com|caiyun\.139\.com)\//i.test(str(u).trim());
  }
  function isSupportedCloudShare(u) {
    return /^https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\//i.test(str(u).trim());
  }
  function panProviderName(u) {
    var s = str(u).toLowerCase();
    if (s.indexOf('pan.quark.cn') >= 0) return '夸克网盘';
    if (s.indexOf('drive.uc.cn') >= 0 || s.indexOf('fast.uc.cn') >= 0) return 'UC网盘';
    if (s.indexOf('pan.baidu.com') >= 0) return '百度网盘';
    if (s.indexOf('aliyundrive.com') >= 0 || s.indexOf('alipan.com') >= 0) return '阿里云盘';
    if (s.indexOf('cloud.189.cn') >= 0) return '天翼云盘';
    if (s.indexOf('123pan.com') >= 0 || s.indexOf('123684.com') >= 0 || s.indexOf('123865.com') >= 0 || s.indexOf('123912.com') >= 0) return '123云盘';
    if (s.indexOf('115.com') >= 0 || s.indexOf('115cdn.com') >= 0) return '115网盘';
    if (s.indexOf('caiyun.139.com') >= 0) return '移动云盘';
    return '网盘分享';
  }
  function toMmShare(rawUrl, rawPwd) {
    var raw = str(rawUrl).trim().replace(/\\\//g, '/').replace(/&amp;/g, '&');
    if (/^https?%3A%2F%2F/i.test(raw)) {
      try { raw = decodeURIComponent(raw); } catch (_) {}
    }
    var fragSub = '';
    var fm = /#(\/list\/share\/[^\s"'<>?&]+)/i.exec(raw);
    if (fm) fragSub = fm[1];
    var m = /(https?:\/\/[^\s"'<>#]+)/i.exec(raw);
    var u = m ? m[1].replace(/[\\),.;]+$/, '') : raw;
    var pwd = str(rawPwd).trim();
    if (!pwd) {
      var pm = /(?:提取码|访问码|密码|pwd|password|pass|code)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(raw);
      if (pm) pwd = pm[1];
    }
    if (pwd && /^[A-Za-z0-9]{4,8}$/.test(pwd) && !/[?&](?:pwd|password|pass)=/i.test(u)) {
      u += (u.indexOf('?') >= 0 ? '&' : '?') + 'pwd=' + encodeURIComponent(pwd);
    }
    if (fragSub && u.indexOf('#') < 0) u += '#' + fragSub;
    return 'mmshare://' + u;
  }
  function pushMergedShare(shares, seenMap, rawUrl, rawPwd, rawLabel) {
    var raw = str(rawUrl).trim().replace(/\\\//g, '/').replace(/&amp;/g, '&');
    if (!raw) return;
    if (/^https?%3A%2F%2F/i.test(raw)) {
      try { raw = decodeURIComponent(raw); } catch (_) {}
    }
    var fragSub = '';
    var fm = /#(\/list\/share\/[^\s"'<>?&]+)/i.exec(raw);
    if (fm) fragSub = fm[1];
    var m = /(https?:\/\/[^\s"'<>#]+)/i.exec(raw);
    if (!m) return;
    var clean = m[1].replace(/[\\),.;]+$/, '');
    if (!isPanShare(clean)) return;
    var p = str(rawPwd).trim();
    if (!p) {
      var pm = /(?:提取码|访问码|密码|pwd|password|pass|code)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(raw + ' ' + str(rawLabel || ''));
      if (pm) p = pm[1];
    }
    var lbl = stripHtml(rawLabel || '');
    var fullClean = fragSub ? (clean + '#' + fragSub) : clean;
    var key = clean.split('?')[0] + (fragSub ? ('#' + fragSub) : '');
    if (seenMap[key]) {
      if (p && !seenMap[key].pwd && !/[?&](?:pwd|password|pass)=/i.test(seenMap[key].url)) {
        seenMap[key].pwd = p;
      }
      if (/[?&](?:pwd|password|pass)=/i.test(clean) && !/[?&](?:pwd|password|pass)=/i.test(seenMap[key].url)) {
        seenMap[key].url = fullClean;
      }
      if (lbl && (!seenMap[key].label || /^https?:\/\//i.test(seenMap[key].label))) {
        seenMap[key].label = lbl;
      }
      return;
    }
    var entry = { url: fullClean, pwd: p, label: lbl };
    seenMap[key] = entry;
    shares.push(entry);
  }
  function encodeShareId(obj) {
    return 'pan1:' + utf8ToB64(JSON.stringify(obj));
  }
  function decodeShareId(raw) {
    var s = str(raw).trim();
    if (s.indexOf('pan1:') === 0) {
      var parsed = parseJsonSafe(b64ToUtf8(s.slice(5)));
      if (isObj(parsed)) return parsed;
    }
    var direct = parseJsonSafe(s);
    if (isObj(direct)) return direct;
    return { title: '网盘资源', url: s, pwd: '' };
  }
  function groupShareTabs(shares) {
    var hasSupported = false;
    for (var s = 0; s < shares.length; s++) {
      if (shares[s] && isSupportedCloudShare(shares[s].url)) { hasSupported = true; break; }
    }
    var groups = {};
    var order = [];
    var seen = {};
    for (var i = 0; i < shares.length; i++) {
      var item = shares[i];
      var u = str(item && item.url).trim();
      if (!u) continue;
      if (hasSupported ? !isSupportedCloudShare(u) : !isPanShare(u)) continue;
      var mm = toMmShare(u, item.pwd);
      if (seen[mm]) continue;
      seen[mm] = true;
      var provider = panProviderName(u);
      if (!groups[provider]) {
        groups[provider] = [];
        order.push(provider);
      }
      var label = stripHtml(item.label || '').replace(/[$#]/g, ' ').trim();
      if (!label || label.length > 60 || /^https?:\/\//i.test(label)) label = '分享' + (groups[provider].length + 1);
      groups[provider].push(label + '$' + mm);
    }
    var froms = [];
    var urls = [];
    for (var j = 0; j < order.length; j++) {
      var k = order[j];
      var items = groups[k];
      if (items.length === 1) {
        froms.push(k);
        urls.push(items[0]);
      } else {
        for (var idx = 0; idx < items.length; idx++) {
          froms.push(k + ' ' + (idx + 1));
          urls.push(items[idx]);
        }
      }
    }
    return { froms: froms, urls: urls };
  }

  var ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  // =========================================================================
  // 1. seedhub-v1 (Seedhub)
  // =========================================================================
  if (cfg.adapter === 'seedhub-v1') {
    var shExtUrl = cfg.extText && /^https?:\/\//i.test(cfg.extText) ? cfg.extText.split(/[|,;\s]+/)[0] : '';
    var shHost = str(cfg.ext.host || cfg.ext.siteUrl || shExtUrl || cfg.defaultHost || cfg.origin).replace(/\/+$/, '');
    var shHeaders = { 'User-Agent': ua, Referer: shHost + '/' };

    var shParseCards = function (html) {
      var out = [];
      var cards = pdfa(html, 'div.cover-container div.cover');
      if (!cards.length) cards = pdfa(html, 'ul.movies li');
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var href = pdfh(c, 'a&&href');
        var name = stripHtml(pdfh(c, 'img&&alt') || pdfh(c, 'a&&title') || pdfh(c, 'h2&&Text') || pdfh(c, 'a&&Text'));
        if (!href || !name) continue;
        var pic = safePic(pdfh(c, 'img&&data-src') || pdfh(c, 'img&&src'), shHost + '/');
        var rem = stripHtml(pdfh(c, '.tag&&Text') || pdfh(c, 'span&&Text'));
        out.push({ vod_id: href, vod_name: name, vod_pic: pic, vod_remarks: rem });
      }
      return out;
    };

    var shResolveRedirect = function (href) {
      var target = address(href, shHost + '/').url;
      if (isPanShare(target)) return target;
      try {
        var html = httpReq(target, { headers: shHeaders, timeout: 6000 }).body;
        var m1 = /var\s+panLink\s*=\s*["']([^"']+)["']/i.exec(html);
        if (m1 && isPanShare(m1[1])) return m1[1];
        var m2 = /const\s+data\s*=\s*["']([A-Za-z0-9+/=_-]{16,})["']/i.exec(html);
        if (m2) {
          var dec = b64ToUtf8(m2[1]);
          var j = parseJsonSafe(dec);
          if (isObj(j) && isPanShare(j.url || j.link)) return str(j.url || j.link);
          if (isPanShare(dec)) return dec.trim();
        }
        var m3 = /(https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+)/i.exec(html);
        if (m3) return m3[1];
      } catch (_) {}
      return '';
    };

    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '剧集' },
          { type_id: '3', type_name: '动漫' }
        ]
      };
    };
    __drpy.homeVod = function () {
      var html = httpReq(shHost + '/', { headers: shHeaders, timeout: 8000 }).body;
      return { list: shParseCards(html) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, parseInt(pg, 10) || 1);
      var ext = isObj(extend) ? extend : {};
      var by = str(ext.by || '');
      var path;
      if (ext.type) {
        path = '/categories/' + encodeURIComponent(str(tid)) + '/types/' + encodeURIComponent(str(ext.type)) + '/movies/?page=' + page;
      } else if (ext.area || ext.year) {
        path = '/categories/' + encodeURIComponent(str(tid)) + '/tags/' + encodeURIComponent(str(ext.area || ext.year)) + '/movies/?page=' + page;
      } else {
        path = '/categories/' + encodeURIComponent(str(tid)) + '/movies/?page=' + page;
      }
      if (by) path += '&order=' + encodeURIComponent(by);
      var html = httpReq(shHost + path, { headers: shHeaders, timeout: 8000 }).body;
      var list = shParseCards(html);
      return { page: page, pagecount: list.length ? page + 1 : page, limit: list.length, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { list: [] };
      var page = Math.max(1, parseInt(pg, 10) || 1);
      var html = httpReq(shHost + '/s/' + encodeURIComponent(kw) + '/?page=' + page, { headers: shHeaders, timeout: 8000 }).body;
      var list = shParseCards(html);
      if (!list.length && page === 1) {
        html = httpReq(shHost + '/?s=' + encodeURIComponent(kw), { headers: shHeaders, timeout: 8000 }).body;
        list = shParseCards(html);
      }
      return { list: list };
    };
    __drpy.detail = function (id) {
      var detailUrl = address(id, shHost + '/').url;
      var html = httpReq(detailUrl, { headers: shHeaders, timeout: 8000 }).body;
      var links = pdfa(html, 'ul.pan-links li a');
      if (!links.length) links = pdfa(html, 'div.pan-links a');
      if (!links.length) links = pdfa(html, 'a[href*=link_start]');
      var shares = [];
      var seenMap = Object.create(null);
      var redirectCount = 0;
      for (var i = 0; i < links.length; i++) {
        var aHtml = links[i];
        var rawLink = pdfh(aHtml, 'a&&data-link') || pdfh(aHtml, 'a&&href');
        var title = stripHtml(pdfh(aHtml, 'a&&title') || pdfh(aHtml, 'a&&Text'));
        if (!rawLink) continue;
        if (isPanShare(rawLink)) {
          pushMergedShare(shares, seenMap, rawLink, '', title);
        } else if (redirectCount < 8) {
          redirectCount++;
          var resolved = shResolveRedirect(rawLink);
          if (resolved) pushMergedShare(shares, seenMap, resolved, '', title);
        }
      }
      var scanHtml = str(html).replace(/\\\//g, '/');
      var directRe = /(https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+)/ig;
      var dm;
      while ((dm = directRe.exec(scanHtml)) !== null) {
        var ctx = scanHtml.slice(dm.index, Math.min(scanHtml.length, dm.index + 240));
        var pm = /(?:提取码|访问码|密码|pwd|password)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(ctx);
        pushMergedShare(shares, seenMap, dm[1], pm ? pm[1] : '', '');
      }
      var grouped = groupShareTabs(shares);
      return {
        list: [{
          vod_id: str(id),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')) || str(id),
          vod_pic: safePic(pdfh(html, 'div.cover img&&src') || pdfh(html, 'article img&&src'), shHost + '/'),
          vod_content: stripHtml(pdfh(html, 'div.summary&&Html') || pdfh(html, 'div.entry-content&&Html')),
          vod_play_from: grouped.froms.join('$$$'),
          vod_play_url: grouped.urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (str(id).indexOf('mmshare://') === 0) return { parse: 0, url: str(id) };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 2. szps-v1 (S_zps / Pansou JSON API)
  // =========================================================================
  if (cfg.adapter === 'szps-v1') {
    var szExtUrl = cfg.extText && /^https?:\/\//i.test(cfg.extText) ? cfg.extText.split(/[|,;\s]+/)[0] : '';
    var szBase = str(cfg.ext.siteUrl || cfg.ext.host || szExtUrl || cfg.defaultHost || cfg.origin).replace(/\/+$/, '') + '/';
    var szSearchPath = str(cfg.ext.searchApi || cfg.searchApiPath || 'api/search?kw=@').replace(/^\/+/, '');
    var szLoginPath = str(cfg.loginPath || 'api/auth/login').replace(/^\/+/, '');
    var szToken = '';

    var szEnsureHeaders = function () {
      var h = { 'User-Agent': ua, Accept: 'application/json' };
      var loginStr = str(cfg.ext.login || '').trim();
      if (loginStr && !szToken) {
        var sep = loginStr.indexOf(':') >= 0 ? ':' : '-';
        var idx = loginStr.indexOf(sep);
        if (idx > 0) {
          var uname = loginStr.slice(0, idx);
          var upass = loginStr.slice(idx + 1);
          try {
            var lr = httpReq(szBase + szLoginPath, {
              method: 'POST',
              headers: { 'User-Agent': ua, 'Content-Type': 'application/json' },
              body: JSON.stringify({ username: uname, password: upass }),
              timeout: 6000
            });
            var lj = parseJsonSafe(lr.body);
            var tk = str((lj && lj.token) || (lj && lj.data && lj.data.token) || '');
            if (tk) szToken = tk;
          } catch (_) {}
        }
      }
      if (szToken) h.Authorization = 'Bearer ' + szToken;
      return h;
    };

    __drpy.home = function () {
      return { class: [{ type_id: '1', type_name: '网盘搜索' }] };
    };
    __drpy.homeVod = function () { return { list: [] }; };
    __drpy.category = function () { return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] }; };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { list: [] };
      var rel = szSearchPath.indexOf('@') >= 0
        ? szSearchPath.replace('@', encodeURIComponent(kw))
        : (szSearchPath + encodeURIComponent(kw));
      if (rel.indexOf('api/search') >= 0 && rel.indexOf('cloud_types=') < 0) {
        rel += (rel.indexOf('?') >= 0 ? '&' : '?') + 'cloud_types=baidu,quark,uc,aliyun&res=merge';
      }
      var resp = httpReq(szBase + rel, { headers: szEnsureHeaders(), timeout: 11500 });
      var j = parseJsonSafe(resp.body);
      if (!isObj(j)) return { list: [] };
      var dataObj = isObj(j.data) ? j.data : j;
      var kwLower = kw.toLowerCase();
      var isArchiveOnly = function (txt) {
        var s = str(txt);
        return /\.(?:zip|rar|7z|tar|gz)(?:\b|$)/i.test(s) && !/\.(?:mkv|mp4|ts|m3u8|mov|avi|flv|iso|m2ts)(?:\b|$)/i.test(s);
      };
      var bucketOrder = ['quark', 'baidu', 'uc', 'aliyun'];
      var rawBuckets = { quark: [], baidu: [], uc: [], aliyun: [], other: [] };
      var seenBase = Object.create(null);
      var anyKwMatch = false;
      var bucketKeyForUrl = function (u) {
        var s = str(u).toLowerCase();
        if (s.indexOf('pan.quark.cn') >= 0) return 'quark';
        if (s.indexOf('pan.baidu.com') >= 0) return 'baidu';
        if (s.indexOf('drive.uc.cn') >= 0 || s.indexOf('fast.uc.cn') >= 0) return 'uc';
        if (s.indexOf('aliyundrive.com') >= 0 || s.indexOf('alipan.com') >= 0) return 'aliyun';
        return 'other';
      };
      var addCandidate = function (title, linkUrl, pwd, dt, extraFiles) {
        var u = str(linkUrl).trim().replace(/\\\//g, '/');
        if (!isSupportedCloudShare(u)) return;
        var baseKey = u.split('?')[0];
        if (seenBase[baseKey]) {
          var prev = seenBase[baseKey];
          var np = str(pwd || '').trim();
          if (np && !prev.pwd) prev.pwd = np;
          return;
        }
        var cleanTitle = stripHtml(title) || kw;
        var matchesKw = cleanTitle.toLowerCase().indexOf(kwLower) >= 0;
        if (matchesKw) anyKwMatch = true;
        var item = {
          title: cleanTitle,
          url: u,
          pwd: str(pwd || '').trim(),
          dt: str(dt || ''),
          archiveOnly: isArchiveOnly(cleanTitle + ' ' + str(extraFiles || '')),
          matchesKw: matchesKw
        };
        seenBase[baseKey] = item;
        var bName = bucketKeyForUrl(u);
        if (!rawBuckets[bName]) { rawBuckets[bName] = []; bucketOrder.push(bName); }
        rawBuckets[bName].push(item);
      };
      if (isObj(dataObj.merged_by_type)) {
        var keys = Object.keys(dataObj.merged_by_type);
        for (var k = 0; k < keys.length; k++) {
          var arr = dataObj.merged_by_type[keys[k]];
          if (!Array.isArray(arr)) continue;
          for (var m = 0; m < arr.length; m++) {
            var it = arr[m];
            if (isObj(it)) addCandidate(it.note || it.title || kw, it.url || it.link, it.password || it.pwd, it.datetime || it.time, it.files);
          }
        }
      }
      if (Array.isArray(dataObj.results)) {
        for (var r = 0; r < dataObj.results.length; r++) {
          var row = dataObj.results[r];
          if (!isObj(row)) continue;
          var rTitle = row.title || kw;
          var links = Array.isArray(row.links) ? row.links : [];
          for (var l = 0; l < links.length; l++) {
            var lk = links[l];
            if (isObj(lk)) addCandidate(rTitle, lk.url, lk.password || lk.pwd, lk.datetime || row.datetime, row.content);
          }
        }
      }
      if (rawBuckets.other.length && bucketOrder.indexOf('other') < 0) bucketOrder.push('other');
      var filteredBuckets = {};
      for (var bi = 0; bi < bucketOrder.length; bi++) {
        var bk = bucketOrder[bi];
        var bArr = (rawBuckets[bk] || []).filter(function (x) {
          return !anyKwMatch || x.matchesKw;
        });
        bArr.sort(function (a, b) {
          if (a.archiveOnly !== b.archiveOnly) return a.archiveOnly ? 1 : -1;
          return b.dt.localeCompare(a.dt);
        });
        filteredBuckets[bk] = bArr;
      }
      var interleaved = [];
      var cursors = Object.create(null);
      var progressed = true;
      while (interleaved.length < 60 && progressed) {
        progressed = false;
        for (var pi = 0; pi < bucketOrder.length && interleaved.length < 60; pi++) {
          var pk = bucketOrder[pi];
          var cur = cursors[pk] || 0;
          var listForPk = filteredBuckets[pk] || [];
          if (cur < listForPk.length) {
            interleaved.push(listForPk[cur]);
            cursors[pk] = cur + 1;
            progressed = true;
          }
        }
      }
      var out = [];
      for (var oi = 0; oi < interleaved.length; oi++) {
        var primary = interleaved[oi];
        var backups = [];
        for (var bj = 0; bj < interleaved.length && backups.length < 3; bj++) {
          if (bj === oi) continue;
          var cand = interleaved[bj];
          if (cand.url !== primary.url && !cand.archiveOnly) {
            backups.push({ url: cand.url, pwd: cand.pwd, label: cand.title });
          }
        }
        out.push({
          vod_id: encodeShareId({ title: primary.title, url: primary.url, pwd: primary.pwd, backups: backups }),
          vod_name: primary.title,
          vod_pic: '',
          vod_remarks: panProviderName(primary.url)
        });
      }
      return { list: out };
    };
    __drpy.detail = function (id) {
      var info = decodeShareId(id);
      var u = str(info.url).trim();
      if (!isSupportedCloudShare(u)) fail('drpy_media_unresolved');
      var title = stripHtml(info.title) || '网盘资源';
      var allShares = [{ url: u, pwd: str(info.pwd || ''), label: title }];
      if (Array.isArray(info.backups)) {
        for (var b = 0; b < info.backups.length; b++) {
          if (isObj(info.backups[b]) && isSupportedCloudShare(info.backups[b].url)) {
            allShares.push(info.backups[b]);
          }
        }
      }
      var grouped = groupShareTabs(allShares);
      return {
        list: [{
          vod_id: str(id),
          vod_name: title,
          vod_pic: '',
          vod_content: title,
          vod_play_from: grouped.froms.join('$$$'),
          vod_play_url: grouped.urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (str(id).indexOf('mmshare://') === 0) return { parse: 0, url: str(id) };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 3 & 4. ypanso-v1 & bpanso-v1 (YpanSo Quark & BpanSo Baidu)
  // =========================================================================
  if (cfg.adapter === 'ypanso-v1' || cfg.adapter === 'bpanso-v1') {
    var psUrl = str(cfg.ext.searchUrl || cfg.ext.api || cfg.searchUrl || (cfg.origin + '/v1/search/disk'));
    var psOrigin = str(cfg.origin).replace(/\/+$/, '');
    var psReferer = str(cfg.referer || (psOrigin + '/'));
    var psSuffix = str(cfg.bodySuffix || '');

    __drpy.home = function () {
      return { class: [{ type_id: '1', type_name: '网盘搜索' }] };
    };
    __drpy.homeVod = function () { return { list: [] }; };
    __drpy.category = function () { return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] }; };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { list: [] };
      var page = Math.max(1, parseInt(pg, 10) || 1);
      var reqBody = psSuffix.charAt(0) === '"'
        ? ('{"page":' + page + ',"q":' + JSON.stringify(kw) + psSuffix.slice(1))
        : JSON.stringify({ page: page, q: kw, user: '', exact: false, format: [], share_time: '', size: 15, type: cfg.adapter === 'bpanso-v1' ? 'BDY' : 'QUARK', exclude_user: [], adv_params: { wechat_pwd: '' } });
      var resp = httpReq(psUrl, {
        method: 'POST',
        headers: {
          'User-Agent': ua,
          'Content-Type': 'application/json',
          Origin: psOrigin,
          Referer: psReferer
        },
        body: reqBody,
        timeout: 8000
      });
      var j = parseJsonSafe(resp.body);
      var rows = (j && j.data && (j.data.list || j.data.datas)) || (j && (j.datas || j.list)) || [];
      if (!Array.isArray(rows)) return { list: [] };
      var parsedRows = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (!isObj(r)) continue;
        var link = str(r.link || r.url).trim();
        if (!link && str(r.disk_id).trim()) {
          var did = str(r.disk_id).trim();
          var dtype = str(r.disk_type || '').toUpperCase();
          if (dtype === 'BDY' || cfg.adapter === 'bpanso-v1') {
            link = 'https://pan.baidu.com/s/' + (did.indexOf('1') === 0 ? did : ('1' + did));
          } else {
            link = 'https://pan.quark.cn/s/' + did;
          }
        }
        if (!isSupportedCloudShare(link)) continue;
        var rawTitle = stripHtml(r.disk_name || r.title || r.name);
        var title = !rawTitle
          ? kw
          : (rawTitle.toLowerCase().indexOf(kw.toLowerCase()) >= 0 ? rawTitle : (kw + ' [' + rawTitle + ']'));
        var pwd = str(r.disk_pass || r.pwd || r.password || '').trim();
        var rem = stripHtml(r.shared_time || r.up_time || '') || panProviderName(link);
        var filesTxt = str(r.files || '') + ' ' + rawTitle;
        var archiveOnly = (/(?:^|\s)zip\s*\n/i.test(str(r.files || '')) || /\.(?:zip|rar|7z|tar|gz)(?:\b|$)/i.test(filesTxt)) &&
          !/\.(?:mkv|mp4|ts|m3u8|mov|avi|flv|iso|m2ts)(?:\b|$)/i.test(filesTxt);
        parsedRows.push({ title: title, url: link, pwd: pwd, rem: rem, archiveOnly: archiveOnly, idx: i });
      }
      parsedRows.sort(function (a, b) {
        if (a.archiveOnly !== b.archiveOnly) return a.archiveOnly ? 1 : -1;
        return a.idx - b.idx;
      });
      var effectiveRows = parsedRows;
      var out = [];
      for (var idx = 0; idx < effectiveRows.length; idx++) {
        var curRow = effectiveRows[idx];
        var backups = [];
        for (var bi = 0; bi < effectiveRows.length && backups.length < 3; bi++) {
          if (bi === idx) continue;
          if (effectiveRows[bi].url !== curRow.url) {
            backups.push({ url: effectiveRows[bi].url, pwd: effectiveRows[bi].pwd, label: effectiveRows[bi].title });
          }
        }
        out.push({
          vod_id: encodeShareId({ title: curRow.title, url: curRow.url, pwd: curRow.pwd, backups: backups }),
          vod_name: curRow.title,
          vod_pic: '',
          vod_remarks: curRow.rem
        });
      }
      return { list: out };
    };
    __drpy.detail = function (id) {
      var info = decodeShareId(id);
      var u = str(info.url).trim();
      if (!isSupportedCloudShare(u)) fail('drpy_media_unresolved');
      var title = stripHtml(info.title) || '网盘资源';
      var allShares = [{ url: u, pwd: str(info.pwd || ''), label: title }];
      if (Array.isArray(info.backups)) {
        for (var b = 0; b < info.backups.length; b++) {
          if (isObj(info.backups[b]) && isSupportedCloudShare(info.backups[b].url)) {
            allShares.push(info.backups[b]);
          }
        }
      }
      var grouped = groupShareTabs(allShares);
      return {
        list: [{
          vod_id: str(id),
          vod_name: title,
          vod_pic: '',
          vod_content: title,
          vod_play_from: grouped.froms.join('$$$'),
          vod_play_url: grouped.urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (str(id).indexOf('mmshare://') === 0) return { parse: 0, url: str(id) };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 5 & 6. kkss-v1 & uuss-v1 (KkSs & UuSs Multi-Mirror MacCMS Pan Search)
  // =========================================================================
  if (cfg.adapter === 'kkss-v1' || cfg.adapter === 'uuss-v1') {
    var kuSites = [];
    var addKuSite = function (raw) {
      var s = str(raw).trim().replace(/\/+$/, '');
      if (!/^https?:\/\/[^/?#@]+$/i.test(s)) {
        try {
          var a = address(s);
          s = a.origin;
        } catch (_) { return; }
      }
      if (s && kuSites.indexOf(s) < 0) kuSites.push(s);
    };
    if (cfg.ext.host || cfg.ext.siteUrl) addKuSite(cfg.ext.host || cfg.ext.siteUrl);
    if (cfg.extText && /^https?:\/\//i.test(cfg.extText)) {
      var extParts = cfg.extText.split(/[|,;\s]+/);
      for (var ep = 0; ep < extParts.length; ep++) addKuSite(extParts[ep]);
    }
    if (Array.isArray(cfg.sites)) {
      for (var cs = 0; cs < cfg.sites.length; cs++) addKuSite(cfg.sites[cs]);
    }
    addKuSite(cfg.origin);
    var kuDetailPath = str(cfg.detailPath || 'index.php/vod/detail/id/').replace(/^\/+/, '');
    var kuActiveSite = '';

    var kuPickSite = function () {
      if (kuActiveSite) return kuActiveSite;
      for (var i = 0; i < Math.min(kuSites.length, 4); i++) {
        try {
          var r = httpReq(kuSites[i] + '/', { headers: { 'User-Agent': ua, Referer: kuSites[i] + '/' }, timeout: 5000 });
          if (r.body && r.body.length > 200) {
            kuActiveSite = kuSites[i];
            return kuActiveSite;
          }
        } catch (_) {}
      }
      kuActiveSite = kuSites[0];
      return kuActiveSite;
    };

    var kuNormalizeDetailHref = function (rawHref) {
      var h = str(rawHref).trim();
      if (!h) return '';
      var m1 = /^(https?:\/\/[^/?#]+)?(\/index\.php)?\/vod\/play\/id\/(\d+)\b[^"'?#]*/i.exec(h);
      if (m1) return (m1[1] || '') + (m1[2] || '/index.php') + '/vod/detail/id/' + m1[3] + '.html';
      var m2 = /^(https?:\/\/[^/?#]+)?(\/index\.php)?\/vodplay\/(\d+)-\d+-\d+\.html\b/i.exec(h);
      if (m2) return (m2[1] || '') + (m2[2] || '') + '/voddetail/' + m2[3] + '.html';
      return h;
    };

    var kuParseModuleItems = function (html, site) {
      var out = [];
      var cards = pdfa(html, 'div.module-items a.module-poster-item');
      if (!cards.length) cards = pdfa(html, 'div.module-item');
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var href = pdfh(c, 'a[href*="/vod/detail/"]&&href') || pdfh(c, 'a[href*="/voddetail/"]&&href') || pdfh(c, 'a&&href');
        if (!href && /^\s*<a\b/i.test(c)) {
          var hm = /\bhref=["']([^"']+)["']/i.exec(c);
          if (hm) href = hm[1];
        }
        href = kuNormalizeDetailHref(href);
        var title = stripHtml(pdfh(c, '.module-poster-item-title&&Text') || pdfh(c, '.module-item-title&&Text') || pdfh(c, 'img&&alt') || pdfh(c, 'a&&title')).replace(/^(?:立刻播放|立即播放)\s*/, '').trim();
        if (!href || !title) continue;
        var pic = safePic(pdfh(c, 'img&&data-original') || pdfh(c, 'img&&data-src') || pdfh(c, 'img&&src'), site + '/');
        var rem = stripHtml(pdfh(c, '.module-item-note&&Text') || pdfh(c, '.module-item-caption&&Text'));
        out.push({
          vod_id: encodeShareId({ site: site, href: href }),
          vod_name: title,
          vod_pic: pic,
          vod_remarks: rem
        });
      }
      return out;
    };

    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '剧集' },
          { type_id: '3', type_name: '综艺' },
          { type_id: '4', type_name: '动漫' }
        ]
      };
    };
    __drpy.homeVod = function () {
      var site = kuPickSite();
      var html = httpReq(site + '/', { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 6000 }).body;
      return { list: kuParseModuleItems(html, site) };
    };
    __drpy.category = function (tid, pg) {
      var site = kuPickSite();
      var page = Math.max(1, parseInt(pg, 10) || 1);
      var url = site + '/index.php/vod/show/id/' + encodeURIComponent(str(tid)) + '/page/' + page + '.html';
      var html = httpReq(url, { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 6000 }).body;
      var list = kuParseModuleItems(html, site);
      return { page: page, pagecount: list.length ? page + 1 : page, limit: list.length, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { list: [] };
      var page = Math.max(1, parseInt(pg, 10) || 1);
      var limit = Math.min(kuSites.length, 3);
      for (var s = 0; s < limit; s++) {
        var site = kuSites[s];
        try {
          var sUrl = page === 1
            ? (site + '/index.php/vod/search.html?wd=' + encodeURIComponent(kw))
            : (site + '/index.php/vod/search/page/' + page + '/wd/' + encodeURIComponent(kw) + '.html');
          var html = httpReq(sUrl, { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 6000 }).body;
          var items = pdfa(html, 'div.module-search-item');
          if (!items.length) items = pdfa(html, 'div.module-card-item');
          var out = [];
          for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var href = kuNormalizeDetailHref(
              pdfh(it, 'a[href*="/vod/detail/"]&&href') ||
              pdfh(it, 'a[href*="/voddetail/"]&&href') ||
              pdfh(it, 'h3 a&&href') ||
              pdfh(it, 'a.module-card-item-poster&&href') ||
              pdfh(it, 'a.video-serial&&href') ||
              pdfh(it, 'a&&href')
            );
            var title = stripHtml(pdfh(it, 'h3 a&&Text') || pdfh(it, '.module-card-item-title a&&Text') || pdfh(it, 'img&&alt') || pdfh(it, 'a&&title')).replace(/^(?:立刻播放|立即播放)\s*/, '').trim();
            if (!href || !title) continue;
            var pic = safePic(pdfh(it, 'img&&data-src') || pdfh(it, 'img&&data-original') || pdfh(it, 'img&&src'), site + '/');
            var rem = stripHtml(pdfh(it, 'a.video-serial&&Text') || pdfh(it, '.module-item-note&&Text'));
            out.push({
              vod_id: encodeShareId({ site: site, href: href }),
              vod_name: title,
              vod_pic: pic,
              vod_remarks: rem
            });
          }
          if (out.length) {
            kuActiveSite = site;
            return { list: out };
          }
        } catch (_) {}
      }
      return { list: [] };
    };
    __drpy.detail = function (id) {
      var info = decodeShareId(id);
      var site = str(info.site || '') || kuPickSite();
      var href = str(info.href || info.url || id);
      if (/^\d+$/.test(href)) href = '/' + kuDetailPath + href + '.html';
      else href = kuNormalizeDetailHref(href);
      var detailUrl = address(href, site + '/').url;
      var html = httpReq(detailUrl, { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 7000 }).body;

      var shares = [];
      var kuSeen = Object.create(null);
      var clipNodes = pdfa(html, '[data-clipboard-text]');
      for (var i = 0; i < clipNodes.length; i++) {
        var cm = /\bdata-clipboard-text=["']([^"']+)["']/i.exec(clipNodes[i]);
        if (cm && isPanShare(cm[1])) pushMergedShare(shares, kuSeen, cm[1], '', stripHtml(clipNodes[i]));
      }
      var rowLinks = pdfa(html, 'div.module-row-info a, div.module-downlist a, #download-list a');
      for (var j = 0; j < rowLinks.length; j++) {
        var lk = pdfh(rowLinks[j], 'a&&href');
        var lb = stripHtml(pdfh(rowLinks[j], 'a&&title') || pdfh(rowLinks[j], 'a&&Text'));
        if (isPanShare(lk)) pushMergedShare(shares, kuSeen, lk, '', lb);
      }
      var scanKuHtml = str(html).replace(/\\\//g, '/');
      var panRe = /(https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+)/ig;
      var pm;
      while ((pm = panRe.exec(scanKuHtml)) !== null) {
        var kuCtx = scanKuHtml.slice(pm.index, Math.min(scanKuHtml.length, pm.index + 240));
        var kpm = /(?:提取码|访问码|密码|pwd|password)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(kuCtx);
        pushMergedShare(shares, kuSeen, pm[1], kpm ? kpm[1] : '', '');
      }
      var grouped = groupShareTabs(shares);
      var froms = grouped.froms.slice();
      var urls = grouped.urls.slice();

      var tabs = pdfa(html, '.module-tab-item span, .module-tab-item');
      var lists = pdfa(html, '.module-play-list');
      for (var t = 0; t < lists.length; t++) {
        var tName = stripHtml(t < tabs.length ? pdfh(tabs[t], 'Text') : ('线路' + (t + 1))) || ('线路' + (t + 1));
        var aList = pdfa(lists[t], 'a');
        var eps = [];
        for (var e = 0; e < aList.length; e++) {
          var epHref = pdfh(aList[e], 'a&&href');
          var epName = stripHtml(pdfh(aList[e], 'a&&Text')) || ('第' + (e + 1) + '集');
          if (!epHref || /^(?:magnet:|ed2k:|thunder:)/i.test(epHref)) continue;
          eps.push(epName.replace(/[$#]/g, ' ') + '$' + encodeShareId({ site: site, playHref: epHref }));
        }
        if (eps.length) {
          froms.push(tName);
          urls.push(eps.join('#'));
        }
      }

      return {
        list: [{
          vod_id: str(id),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, '.page-title&&Text')) || str(id),
          vod_pic: safePic(pdfh(html, '.module-item-pic img&&data-src') || pdfh(html, '.module-item-pic img&&src'), site + '/'),
          vod_content: stripHtml(pdfh(html, '.video-info-content&&Html') || pdfh(html, '.zkjj_a&&Html')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var s = str(id);
      if (s.indexOf('mmshare://') === 0) return { parse: 0, url: s };
      var info = decodeShareId(s);
      if (info && info.playHref) {
        var site = str(info.site || '') || kuPickSite();
        var pUrl = address(info.playHref, site + '/').url;
        var html = httpReq(pUrl, { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 7000 }).body;
        var m = /var\s+player_(?:aaaa|data)\s*=\s*(\{[\s\S]*?\})\s*</i.exec(html);
        if (m) {
          var pj = parseJsonSafe(m[1]);
          if (isObj(pj) && pj.url) {
            var u = str(pj.url);
            if (Number(pj.encrypt) === 1) u = unescape(u);
            else if (Number(pj.encrypt) === 2) u = unescape(b64ToUtf8(u));
            if (/^https?:\/\/[^?#]+\.(?:m3u8|mp4|flv)(?:[?#]|$)/i.test(u)) {
              return { parse: 0, url: address(u).url, header: { 'User-Agent': ua, Referer: site + '/' } };
            }
          }
        }
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  fail('drpy_source_unavailable');
}

module.exports = function ftyPanRule(config) {
  if (!config || !PAN_ADAPTERS.includes(config.adapter) || !/^https?:\/\//.test(config.origin)) {
    throw Error('endpoint configuration required');
  }
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:15000,预处理:"js:rule._install();",_install:' + installFtyPan.toString() + '};';
};

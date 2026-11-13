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
  function checkChallenge(body) {
    var t = str(body);
    if (!t) return;
    if (/(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|Checking your browser|系统安全验证|正在验证您的浏览器|人机验证|verify you are human|验证码不正确|请完成滑块验证|verifySlider|challenges\.cloudflare\.com|<title>\s*Just a moment\.\.\.\s*<\/title>|Attention Required!\s*\|\s*Cloudflare|cf-turnstile)/i.test(t) ||
        /<input[^>]+(?:name|id)=["']?(?:verify|validate|captcha)/i.test(t)) {
      fail('drpy_verification_required');
    }
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
    if (!c || /(?:sogoucdn\.com|imagehub\.cc)/i.test(c)) return '';
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
    var res = req(target, opts || {});
    var body = res && typeof res.content === 'string' ? res.content : '';
    checkChallenge(body);
    return { body: body, headers: (res && res.headers) || {}, code: (res && res.code) || 0 };
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
    var u = str(rawUrl).trim().replace(/&amp;/g, '&');
    var m = /(https?:\/\/[^\s"'<>#]+)/i.exec(u);
    if (m) u = m[1];
    var pwd = str(rawPwd).trim();
    if (!pwd) {
      var pm = /(?:提取码|密码|pwd|pass|code)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(str(rawUrl));
      if (pm) pwd = pm[1];
    }
    if (pwd && /^[A-Za-z0-9]{4,8}$/.test(pwd) && !/[?&](?:pwd|password|pass)=/i.test(u)) {
      u += (u.indexOf('?') >= 0 ? '&' : '?') + 'pwd=' + encodeURIComponent(pwd);
    }
    return 'mmshare://' + u;
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
    var groups = {};
    var order = [];
    var seen = {};
    for (var i = 0; i < shares.length; i++) {
      var item = shares[i];
      var u = str(item && item.url).trim();
      if (!u || !isSupportedCloudShare(u)) continue;
      var mm = toMmShare(u, item.pwd);
      if (seen[mm]) continue;
      seen[mm] = true;
      var provider = panProviderName(u);
      if (!groups[provider]) {
        groups[provider] = [];
        order.push(provider);
      }
      var label = stripHtml(item.label || '').replace(/[$#]/g, ' ').trim();
      if (!label) label = '分享' + (groups[provider].length + 1);
      groups[provider].push(label + '$' + mm);
    }
    var froms = [];
    var urls = [];
    for (var j = 0; j < order.length; j++) {
      var k = order[j];
      if (groups[k].length) {
        froms.push(k);
        urls.push(groups[k].join('#'));
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
      var redirectCount = 0;
      for (var i = 0; i < links.length; i++) {
        var aHtml = links[i];
        var rawLink = pdfh(aHtml, 'a&&data-link') || pdfh(aHtml, 'a&&href');
        var title = stripHtml(pdfh(aHtml, 'a&&title') || pdfh(aHtml, 'a&&Text'));
        if (!rawLink) continue;
        if (isPanShare(rawLink)) {
          shares.push({ url: rawLink, pwd: '', label: title });
        } else if (redirectCount < 8) {
          redirectCount++;
          var resolved = shResolveRedirect(rawLink);
          if (resolved) shares.push({ url: resolved, pwd: '', label: title });
        }
      }
      if (!shares.length) {
        var directRe = /(https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+)/ig;
        var dm;
        while ((dm = directRe.exec(html)) !== null) {
          shares.push({ url: dm[1], pwd: '', label: '' });
        }
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
      var resp = httpReq(szBase + rel, { headers: szEnsureHeaders(), timeout: 8000 });
      var j = parseJsonSafe(resp.body);
      if (!isObj(j)) return { list: [] };
      var dataObj = isObj(j.data) ? j.data : j;
      var out = [];
      var seen = {};
      var pushShare = function (title, linkUrl, pwd) {
        var u = str(linkUrl).trim();
        if (!isSupportedCloudShare(u) || seen[u] || out.length >= 60) return;
        seen[u] = true;
        var cleanTitle = stripHtml(title) || kw;
        out.push({
          vod_id: encodeShareId({ title: cleanTitle, url: u, pwd: str(pwd || '') }),
          vod_name: cleanTitle,
          vod_pic: '',
          vod_remarks: panProviderName(u)
        });
      };
      if (isObj(dataObj.merged_by_type)) {
        var keys = Object.keys(dataObj.merged_by_type);
        for (var k = 0; k < keys.length; k++) {
          var arr = dataObj.merged_by_type[keys[k]];
          if (!Array.isArray(arr)) continue;
          for (var m = 0; m < arr.length; m++) {
            var it = arr[m];
            if (isObj(it)) pushShare(it.note || it.title || kw, it.url || it.link, it.password || it.pwd);
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
            if (isObj(lk)) pushShare(rTitle, lk.url, lk.password || lk.pwd);
          }
        }
      }
      return { list: out };
    };
    __drpy.detail = function (id) {
      var info = decodeShareId(id);
      var u = str(info.url).trim();
      if (!isSupportedCloudShare(u)) fail('drpy_media_unresolved');
      var provider = panProviderName(u);
      var title = stripHtml(info.title) || '网盘资源';
      return {
        list: [{
          vod_id: str(id),
          vod_name: title,
          vod_pic: '',
          vod_content: title,
          vod_play_from: provider,
          vod_play_url: title.replace(/[$#]/g, ' ') + '$' + toMmShare(u, info.pwd)
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
      var out = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (!isObj(r)) continue;
        var link = str(r.link || r.url).trim();
        if (!isSupportedCloudShare(link)) continue;
        var title = stripHtml(r.disk_name || r.title || r.name) || kw;
        var pwd = str(r.disk_pass || r.pwd || r.password || '').trim();
        var rem = stripHtml(r.shared_time || r.up_time || '') || panProviderName(link);
        out.push({
          vod_id: encodeShareId({ title: title, url: link, pwd: pwd }),
          vod_name: title,
          vod_pic: '',
          vod_remarks: rem
        });
      }
      return { list: out };
    };
    __drpy.detail = function (id) {
      var info = decodeShareId(id);
      var u = str(info.url).trim();
      if (!isSupportedCloudShare(u)) fail('drpy_media_unresolved');
      var provider = panProviderName(u);
      var title = stripHtml(info.title) || '网盘资源';
      return {
        list: [{
          vod_id: str(id),
          vod_name: title,
          vod_pic: '',
          vod_content: title,
          vod_play_from: provider,
          vod_play_url: title.replace(/[$#]/g, ' ') + '$' + toMmShare(u, info.pwd)
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

    var kuParseModuleItems = function (html, site) {
      var out = [];
      var cards = pdfa(html, 'div.module-items a.module-poster-item');
      if (!cards.length) cards = pdfa(html, 'div.module-item');
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var href = pdfh(c, 'a&&href');
        if (!href && /^\s*<a\b/i.test(c)) {
          var hm = /\bhref=["']([^"']+)["']/i.exec(c);
          if (hm) href = hm[1];
        }
        var title = stripHtml(pdfh(c, 'a&&title') || pdfh(c, '.module-poster-item-title&&Text') || pdfh(c, 'img&&alt'));
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
            var href = pdfh(it, 'a.video-serial&&href') || pdfh(it, 'h3 a&&href') || pdfh(it, 'a.module-card-item-poster&&href') || pdfh(it, 'a&&href');
            var title = stripHtml(pdfh(it, 'h3 a&&Text') || pdfh(it, '.module-card-item-title a&&Text') || pdfh(it, 'img&&alt') || pdfh(it, 'a&&title'));
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
      var detailUrl = address(href, site + '/').url;
      var html = httpReq(detailUrl, { headers: { 'User-Agent': ua, Referer: site + '/' }, timeout: 7000 }).body;

      var shares = [];
      var clipNodes = pdfa(html, '[data-clipboard-text]');
      for (var i = 0; i < clipNodes.length; i++) {
        var cm = /\bdata-clipboard-text=["']([^"']+)["']/i.exec(clipNodes[i]);
        if (cm && isPanShare(cm[1])) shares.push({ url: cm[1], pwd: '', label: '' });
      }
      var rowLinks = pdfa(html, 'div.module-row-info a, div.module-downlist a, #download-list a');
      for (var j = 0; j < rowLinks.length; j++) {
        var lk = pdfh(rowLinks[j], 'a&&href');
        var lb = stripHtml(pdfh(rowLinks[j], 'a&&title') || pdfh(rowLinks[j], 'a&&Text'));
        if (isPanShare(lk)) shares.push({ url: lk, pwd: '', label: lb });
      }
      if (!shares.length) {
        var panRe = /(https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+)/ig;
        var pm;
        while ((pm = panRe.exec(html)) !== null) {
          shares.push({ url: pm[1], pwd: '', label: '' });
        }
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
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:10000,预处理:"js:rule._install();",_install:' + installFtyPan.toString() + '};';
};

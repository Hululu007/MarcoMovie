// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';

const { WEX_ADAPTERS, VOD_WEX_ADAPTERS } = require('./drpy-wex-extractor.cjs');
const PAN_WEX_ADAPTERS = Object.freeze(WEX_ADAPTERS.filter(a => !VOD_WEX_ADAPTERS.includes(a)));

function installWexPan() {
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
    if (/(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|Checking your browser|系统安全验证|正在验证您的浏览器|人机验证|verify you are human|验证码不正确|请完成滑块验证|verifySlider)/i.test(t) ||
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
  function cleanHeaders(raw) {
    var out = {};
    if (!isObj(raw)) return out;
    var keys = Object.keys(raw);
    for (var i = 0; i < keys.length; i++) {
      var k = str(keys[i]).trim();
      var v = str(raw[keys[i]]).replace(/[\r\n\0]/g, '').trim();
      if (k && v) out[k] = v;
    }
    return out;
  }
  function utf8ToB64(textVal) {
    return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(str(textVal)));
  }
  function b64ToUtf8(b64Val) {
    var clean = str(b64Val).trim().replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    return CryptoJS.enc.Base64.parse(clean).toString(CryptoJS.enc.Utf8);
  }
  function aesCbcDecryptText(cipherB64, keyStr, ivStr) {
    var clean = str(cipherB64).trim().replace(/\\/g, '').replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    var algo = keyStr.length > 16 ? 'aes-256-cbc' : 'aes-128-cbc';
    var out = nodeCipher('decrypt', algo, utf8ToB64(keyStr), utf8ToB64(ivStr), clean, '');
    return b64ToUtf8(out.data);
  }
  function randomHex(len) {
    var arr = new Uint8Array(Math.ceil(len / 2));
    crypto.getRandomValues(arr);
    var s = '';
    for (var i = 0; i < arr.length; i++) s += ('0' + arr[i].toString(16)).slice(-2);
    return s.slice(0, len);
  }
  function parseJsonSafe(raw) {
    var t = str(raw).replace(/^\uFEFF/, '').trim();
    if (!t) return null;
    try { return JSON.parse(t); } catch (_) { return null; }
  }
  function httpReq(url, opts) {
    var target = address(url).url;
    var o = Object.assign({ timeout: 10000 }, opts || {});
    if (o.headers) o.headers = cleanHeaders(o.headers);
    var res;
    try { res = req(target, o); }
    catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    var body = res && typeof res.content === 'string' ? res.content : '';
    checkChallenge(body);
    return { body: body, headers: (res && res.headers) || {}, code: (res && res.code) || 0 };
  }
  function httpReqSoft(url, opts) {
    try {
      var target = address(url).url;
      var o = Object.assign({ timeout: 6000 }, opts || {});
      if (o.headers) o.headers = cleanHeaders(o.headers);
      var res = req(target, o);
      if (!res || typeof res.content !== 'string') return null;
      checkChallenge(res.content);
      return { body: res.content, headers: res.headers || {}, code: res.code || 0 };
    } catch (e) {
      if (e && e.message === 'drpy_verification_required') fail('drpy_verification_required');
      return null;
    }
  }
  function decryptRemoteText(raw) {
    var s = str(raw).replace(/^\uFEFF/, '').trim();
    if (!s) return '';
    if (/^[\{\[]|^https?:\/\//i.test(s)) return s;
    try {
      return aesCbcDecryptText(s, str(cfg.remoteAesKey), str(cfg.remoteAesIv)).replace(/^\uFEFF/, '').trim();
    } catch (_) { return ''; }
  }
  function loadRemoteWexConfig() {
    var cached = local.get('wex-remote', 'cfg_v1');
    if (isObj(cached) && Number(cached.exp) > Date.now() && (str(cached.siteUrl) || (isObj(cached.siteConfig) && Object.keys(cached.siteConfig).length))) {
      return cached;
    }
    var rHeaders = { 'User-Agent': str(cfg.remoteUa || cfg.userAgent || 'Mozilla/5.0'), Accept: 'application/json,text/plain,*/*' };
    var apiUrls = [cfg.apiTxt0, cfg.apiTxt1, cfg.apiTxt2, cfg.apiTxt3].map(str).filter(Boolean);
    var siteUrl = '';
    for (var i = 0; i < apiUrls.length; i++) {
      var r = httpReqSoft(apiUrls[i], { headers: rHeaders, timeout: 4500 });
      if (r && r.code >= 200 && r.code < 300) {
        var dec = decryptRemoteText(r.body).split(/[\r\n]+/)[0].trim().replace(/\/+$/, '');
        if (/^https?:\/\//i.test(dec)) { siteUrl = dec; break; }
      }
    }
    var siteConfig = {};
    var itemUrls = [cfg.itemTxt0, cfg.itemTxt1, cfg.itemTxt2].map(str).filter(Boolean);
    for (var j = 0; j < itemUrls.length; j++) {
      var ir = httpReqSoft(itemUrls[j], { headers: rHeaders, timeout: 4500 });
      if (ir && ir.code >= 200 && ir.code < 300) {
        var itemObj = parseJsonSafe(decryptRemoteText(ir.body));
        if (isObj(itemObj)) {
          var csUrl = str(itemObj.config_site).trim();
          if (/^https?:\/\//i.test(csUrl)) {
            var sr = httpReqSoft(csUrl, { headers: rHeaders, timeout: 4500 });
            if (sr && sr.code >= 200 && sr.code < 300) {
              var sc = parseJsonSafe(decryptRemoteText(sr.body));
              if (isObj(sc)) siteConfig = sc;
            }
          }
          break;
        }
      }
    }
    var out = {
      siteUrl: siteUrl,
      mySiteUrl: siteUrl ? (siteUrl + str(cfg.mySiteSuffix)) : '',
      siteConfig: siteConfig,
      exp: Date.now() + 20 * 60 * 1000
    };
    if (siteUrl || Object.keys(siteConfig).length) local.set('wex-remote', 'cfg_v1', out);
    return out;
  }
  function pickSiteHosts(siteKeys, fallbacks) {
    var list = [];
    function pushHost(u) {
      var v = str(u).trim().replace(/\/+$/, '');
      if (/^https?:\/\/[^/?#@]+$/i.test(v) && list.indexOf(v) < 0) list.push(v);
    }
    if (isObj(cfg.ext)) {
      pushHost(cfg.ext.site); pushHost(cfg.ext.siteUrl); pushHost(cfg.ext.host); pushHost(cfg.ext.url);
    }
    if (/^https?:\/\//i.test(str(cfg.extText))) {
      var parts = str(cfg.extText).split(/[|,;\s]+/);
      for (var p = 0; p < parts.length; p++) pushHost(parts[p]);
    }
    var keysArr = Array.isArray(siteKeys) ? siteKeys : (siteKeys ? [siteKeys] : []);
    if (keysArr.length && cfg.apiTxt0) {
      var rc = loadRemoteWexConfig();
      var sc = rc && isObj(rc.siteConfig) ? rc.siteConfig : {};
      for (var ki = 0; ki < keysArr.length; ki++) {
        var entry = sc[keysArr[ki]];
        if (Array.isArray(entry)) {
          for (var k = 0; k < entry.length; k++) pushHost(entry[k]);
        } else if (typeof entry === 'string') {
          var ep = entry.split(/[|,;\s]+/);
          for (var m = 0; m < ep.length; m++) pushHost(ep[m]);
        }
      }
    }
    if (Array.isArray(fallbacks)) {
      for (var f = 0; f < fallbacks.length; f++) pushHost(fallbacks[f]);
    }
    if (!list.length) pushHost(cfg.origin);
    return list;
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
    return '网盘分享';
  }
  function toMmShare(rawUrl, rawPwd) {
    var u = str(rawUrl).trim().replace(/&amp;/g, '&');
    if (/^https?%3A%2F%2F/i.test(u)) {
      try { u = decodeURIComponent(u); } catch (_) {}
    }
    var m = /(https?:\/\/[^\s"'<>#]+)/i.exec(u);
    if (m) u = m[1];
    var pwd = str(rawPwd).trim();
    if (!pwd) {
      var pm = /(?:提取码|访问码|密码|pwd|password|pass|code)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(str(rawUrl));
      if (pm) pwd = pm[1];
    }
    if (pwd && /^[A-Za-z0-9]{4,8}$/.test(pwd) && !/[?&](?:pwd|password|pass)=/i.test(u)) {
      u += (u.indexOf('?') >= 0 ? '&' : '?') + 'pwd=' + encodeURIComponent(pwd);
    }
    return 'mmshare://' + u;
  }
  function extractSharesFromHtml(html) {
    var shares = [], seen = {};
    function add(rawU, pwd, label) {
      var u = str(rawU).trim().replace(/&amp;/g, '&');
      if (/^https?%3A%2F%2F/i.test(u)) {
        try { u = decodeURIComponent(u); } catch (_) {}
      }
      var m = /(https?:\/\/[^\s"'<>#]+)/i.exec(u);
      if (!m) return;
      var clean = m[1].replace(/[\\),.;]+$/, '');
      if (!isSupportedCloudShare(clean)) return;
      var key = clean.split('?')[0];
      if (seen[key]) return;
      seen[key] = true;
      var p = str(pwd).trim();
      if (!p) {
        var pm = /(?:提取码|访问码|密码|pwd|password|pass|code)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(u);
        if (pm) p = pm[1];
      }
      shares.push({ url: clean, pwd: p, label: stripHtml(label || '') });
    }
    var clipNodes = pdfa(html, '[data-clipboard-text], [data-copy]');
    for (var i = 0; i < clipNodes.length; i++) {
      var c = clipNodes[i];
      var clip = pdfh(c, '[data-clipboard-text]&&data-clipboard-text') || pdfh(c, '[data-copy]&&data-copy');
      var lbl = pdfh(c, 'h4&&Text') || pdfh(c, 'span&&Text') || stripHtml(c);
      add(clip, '', lbl);
    }
    var anchors = pdfa(html, 'a[href]');
    for (var j = 0; j < anchors.length; j++) {
      var a = anchors[j];
      var href = pdfh(a, 'a&&href');
      if (href) add(href, '', stripHtml(a));
    }
    var encRe = /https?%3A%2F%2F(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)%2F[^\s"'<>&#]+/gi, em;
    while ((em = encRe.exec(html)) !== null) {
      try { add(decodeURIComponent(em[0]), '', ''); } catch (_) {}
    }
    var rawRe = /https?:\/\/(?:pan\.quark\.cn|drive\.uc\.cn|fast\.uc\.cn|pan\.baidu\.com|(?:www\.)?(?:aliyundrive|alipan)\.com)\/[^\s"'<>\\]+/gi, rm;
    while ((rm = rawRe.exec(html)) !== null) {
      var ctx = html.slice(rm.index, Math.min(html.length, rm.index + 240));
      var pm = /(?:提取码|访问码|密码|pwd|password)[:：\s=]*([A-Za-z0-9]{4,8})/i.exec(ctx);
      add(rm[0], pm ? pm[1] : '', '');
    }
    return shares;
  }
  function groupShareTabs(shares) {
    var groups = {}, order = [], seen = {};
    for (var i = 0; i < shares.length; i++) {
      var item = shares[i];
      var u = str(item && item.url).trim();
      if (!u || !isSupportedCloudShare(u)) continue;
      var mm = toMmShare(u, item.pwd);
      if (seen[mm]) continue;
      seen[mm] = true;
      var provider = panProviderName(u);
      if (!groups[provider]) { groups[provider] = []; order.push(provider); }
      var label = stripHtml(item.label || '').replace(/[$#]/g, ' ').trim();
      if (!label || label.length > 60 || /^https?:\/\//i.test(label)) label = '分享' + (groups[provider].length + 1);
      groups[provider].push(label + '$' + mm);
    }
    var froms = [], urls = [];
    for (var j = 0; j < order.length; j++) {
      var k = order[j];
      if (groups[k].length) { froms.push(k); urls.push(groups[k].join('#')); }
    }
    return { froms: froms, urls: urls };
  }
  function encodeShareId(obj) { return 'pan1:' + utf8ToB64(JSON.stringify(obj)); }
  function decodeShareId(raw) {
    var s = str(raw).trim();
    if (s.indexOf('pan1:') === 0) {
      var p = parseJsonSafe(b64ToUtf8(s.slice(5)));
      if (isObj(p)) return p;
    }
    return { title: '网盘资源', url: s, pwd: '' };
  }
  function defaultPlay(flag, id) {
    var s = str(id).trim();
    if (s.indexOf('mmshare://') === 0) return { parse: 0, url: s };
    if (isSupportedCloudShare(s)) return { parse: 0, url: toMmShare(s, '') };
    fail('drpy_media_unresolved');
  }

  var ua = str(cfg.userAgent || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36');

  // =========================================================================
  // Groups 1–3: MacCMS Pan Spiders (8 AiMacPanSite + wexwogg-v1 + wexhuajuan-v1)
  // =========================================================================
  var macPanAdapters = [
    'wexduoduo-v1', 'wexhuban-v1', 'wexkuaiying-v1', 'wexlabi-v1',
    'wexmuou-v1', 'wexshandian-v1', 'wexxiaopan-v1', 'wexzhizhen-v1',
    'wexwogg-v1', 'wexhuajuan-v1'
  ];
  if (macPanAdapters.indexOf(cfg.adapter) >= 0) {
    var mpHosts = pickSiteHosts(str(cfg.siteKey), [cfg.defaultHost]);
    var mpHost = mpHosts[0];
    function mpHtml(path) {
      for (var i = 0; i < mpHosts.length; i++) {
        var full = /^https?:\/\//i.test(path) ? path : (mpHosts[i] + (path.charAt(0) === '/' ? '' : '/') + path);
        var r = httpReqSoft(full, { headers: { 'User-Agent': ua, Referer: mpHosts[i] + '/' }, timeout: 9000 });
        if (r && r.code >= 200 && r.code < 400 && str(r.body)) {
          mpHost = mpHosts[i];
          return r.body;
        }
      }
      fail('drpy_source_unavailable');
    }
    function mpParseCards(html) {
      var cards = pdfa(html, '.module-search-item, .module-item');
      var out = [], seen = {};
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        var href = pdfh(c, 'a&&href');
        if (!href || seen[href]) continue;
        var name = stripHtml(pdfh(c, 'a&&title') || pdfh(c, 'img&&alt') || pdfh(c, 'h3 a&&Text') || pdfh(c, '.module-item-title&&Text'));
        if (!name) continue;
        seen[href] = true;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(c, 'img&&data-src') || pdfh(c, 'img&&data-original') || pdfh(c, 'img&&src'), mpHost + '/'),
          vod_remarks: stripHtml(pdfh(c, '.module-item-text&&Text') || pdfh(c, '.video-serial&&Text'))
        });
      }
      return out;
    }
    __drpy.home = function () {
      if (cfg.adapter === 'wexwogg-v1') {
        return {
          class: [
            { type_id: '1', type_name: '玩偶电影' }, { type_id: '2', type_name: '玩偶剧集' },
            { type_id: '3', type_name: '玩偶动漫' }, { type_id: '4', type_name: '玩偶综艺' },
            { type_id: '44', type_name: '臻彩视界' }, { type_id: '6', type_name: '玩偶短剧' }
          ],
          filters: {}
        };
      }
      var html = mpHtml('/');
      var navs = pdfa(html, 'a[href*="/vod/type/id/"], a[href*="/vod/show/id/"], a[href*="/vodshow/"]');
      var classes = [], seen = {};
      for (var i = 0; i < navs.length; i++) {
        var href = pdfh(navs[i], 'a&&href');
        var m = /(?:\/id\/|\/vodshow\/)(\d+)/i.exec(href);
        var nm = stripHtml(navs[i]);
        if (m && nm && nm.length <= 10 && !seen[m[1]]) {
          seen[m[1]] = true;
          classes.push({ type_id: m[1], type_name: nm });
        }
      }
      if (!classes.length) {
        classes = [
          { type_id: '1', type_name: '电影' }, { type_id: '2', type_name: '剧集' },
          { type_id: '3', type_name: '动漫' }, { type_id: '4', type_name: '综艺' }
        ];
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      return { list: mpParseCards(mpHtml('/')) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var cid = str(ext.cateId || tid);
      var list = [];
      if (cfg.adapter === 'wexwogg-v1') {
        list = mpParseCards(mpHtml('/index.php/vodshow/' + cid + '-' + str(ext.area) + '-' + str(ext.by || 'time') + '-' + str(ext.class) + '-' + str(ext.lang) + '----' + page + '---' + str(ext.year) + '.html'));
      } else {
        var p = '/index.php/vod/show';
        if (str(ext.area)) p += '/area/' + encodeURIComponent(str(ext.area));
        if (str(ext.by)) p += '/by/' + encodeURIComponent(str(ext.by));
        if (str(ext.class)) p += '/class/' + encodeURIComponent(str(ext.class));
        p += '/id/' + encodeURIComponent(cid) + '/page/' + page;
        if (str(ext.year)) p += '/year/' + encodeURIComponent(str(ext.year));
        p += '.html';
        list = mpParseCards(mpHtml(p));
      }
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      if (cfg.adapter === 'wexhuajuan-v1' && page === 1) {
        var sug = httpReqSoft(mpHost + '/index.php/ajax/suggest?mid=1&wd=' + encodeURIComponent(kw) + '&limit=50', { headers: { 'User-Agent': ua, Referer: mpHost + '/' } });
        var sj = sug ? parseJsonSafe(sug.body) : null;
        if (isObj(sj) && Array.isArray(sj.list) && sj.list.length) {
          var sList = sj.list.map(function (it) {
            if (!isObj(it) || !it.id || !it.name) return null;
            return { vod_id: '/index.php/vod/detail/id/' + it.id + '.html', vod_name: str(it.name), vod_pic: safePic(it.pic, mpHost + '/'), vod_remarks: '' };
          }).filter(Boolean);
          if (sList.length) return { page: 1, pagecount: 1, limit: 50, total: sList.length, list: sList };
        }
      }
      var paths = cfg.adapter === 'wexwogg-v1'
        ? ['/index.php/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---.html']
        : ['/index.php/vod/search/page/' + page + '/wd/' + encodeURIComponent(kw) + '.html', '/index.php/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---.html'];
      var list = [];
      for (var i = 0; i < paths.length && !list.length; i++) {
        var r = httpReqSoft(mpHost + paths[i], { headers: { 'User-Agent': ua, Referer: mpHost + '/' }, timeout: 9000 });
        if (r && str(r.body)) list = mpParseCards(r.body);
      }
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var vPath = /^\d+$/.test(str(vid).trim()) ? ('/index.php/vod/detail/id/' + str(vid).trim() + '.html') : str(vid);
      var html = mpHtml(vPath);
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1.page-title&&Text') || pdfh(html, '.video-info-header h1&&Text') || pdfh(html, 'h1&&Text')),
          vod_pic: safePic(pdfh(html, '.module-item-pic img&&data-src') || pdfh(html, '.lazyload&&data-src') || pdfh(html, 'img&&src'), mpHost + '/'),
          vod_content: stripHtml(pdfh(html, '.video-info-content&&Text') || pdfh(html, '.vod_content&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 4: wexjutou-v1 (AiNewJuTou)
  // =========================================================================
  if (cfg.adapter === 'wexjutou-v1') {
    var jtHost = pickSiteHosts(str(cfg.siteKey || 'jutou'), [cfg.defaultHost])[0];
    var jtHeaders = { 'User-Agent': ua, Referer: jtHost + '/' };
    function jtCards(html) {
      var rows = pdfa(html, 'main ul li, .post-list li, ul li');
      var out = [], seen = {};
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var href = pdfh(r, 'div.a a&&href') || pdfh(r, 'h2 a&&href') || pdfh(r, 'a&&href');
        var name = stripHtml(pdfh(r, 'div.a a&&Text') || pdfh(r, 'h2 a&&Text') || pdfh(r, 'a&&title'));
        if (!href || !name || seen[href] || /\/(?:ju|mv|dm|zy|wj|rh|ym|search)(?:_|\b|\/)/i.test(href)) continue;
        seen[href] = true;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(r, 'img&&data-src') || pdfh(r, 'img&&src'), jtHost + '/'),
          vod_remarks: ''
        });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: 'ju', type_name: '国剧' }, { type_id: 'mv', type_name: '电影' },
          { type_id: 'dm', type_name: '动漫' }, { type_id: 'zy', type_name: '综艺' },
          { type_id: 'wj', type_name: '外剧' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return { list: jtCards(httpReq(jtHost + '/', { headers: jtHeaders }).body) }; };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? ('/' + str(tid) + '_' + page + '/') : ('/' + str(tid) + '/');
      var list = jtCards(httpReq(jtHost + path, { headers: jtHeaders }).body);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var list = jtCards(httpReq(jtHost + '/search/?keyword=' + encodeURIComponent(kw) + '&page=' + page, { headers: jtHeaders }).body);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), jtHost + '/').url, { headers: jtHeaders }).body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'main article h1&&Text') || pdfh(html, 'h1&&Text')),
          vod_pic: safePic(pdfh(html, 'article img&&src'), jtHost + '/'),
          vod_content: stripHtml(pdfh(html, 'article p&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 5: wexzhinan-v1 (AiNewZhiNan4K)
  // =========================================================================
  if (cfg.adapter === 'wexzhinan-v1') {
    var znHost = pickSiteHosts('', [cfg.defaultHost])[0];
    var znHeaders = { 'User-Agent': ua, Referer: znHost + '/' };
    function znCards(html) {
      var rows = pdfa(html, '.posts-item.book-item, article.posts-item');
      var out = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var href = pdfh(r, '.item-header a&&href') || pdfh(r, 'h3 a&&href') || pdfh(r, 'a&&href');
        var name = stripHtml(pdfh(r, 'h3 a&&Text') || pdfh(r, 'h2 a&&Text') || pdfh(r, 'a&&title'));
        if (!href || !name) continue;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(r, 'img&&data-src') || pdfh(r, 'img&&src'), znHost + '/'),
          vod_remarks: ''
        });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '/books/juji', type_name: '剧集' },
          { type_id: '/books/dianying', type_name: '电影' },
          { type_id: '/books/zuixin', type_name: '最新' },
          { type_id: '/books/top250', type_name: 'Top250' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return { list: znCards(httpReq(znHost + '/books/zuixin', { headers: znHeaders }).body) }; };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? (str(tid) + '/page/' + page) : str(tid);
      var list = znCards(httpReq(znHost + path, { headers: znHeaders }).body);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var path = (page > 1 ? ('/page/' + page) : '') + '/?post_type=book&s=' + encodeURIComponent(kw);
      var list = znCards(httpReq(znHost + path, { headers: znHeaders }).body);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), znHost + '/').url, { headers: znHeaders }).body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.book-cover img&&data-src') || pdfh(html, '.book-cover img&&src'), znHost + '/'),
          vod_content: stripHtml(pdfh(html, '.post-content&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 6: wexwoniu-v1 (AiNewWoNiu4K)
  // =========================================================================
  if (cfg.adapter === 'wexwoniu-v1') {
    var wnHost = pickSiteHosts(str(cfg.siteKey || 'woniu4k'), [cfg.defaultHost])[0];
    var wnHeaders = { 'User-Agent': ua, Referer: wnHost + '/' };
    function wnCards(html) {
      var out = [], seen = {};
      var re = /<a[^>]+href=["']([^"']*\/voddetail\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, m;
      while ((m = re.exec(html)) !== null) {
        var href = m[1];
        if (seen[href]) continue;
        var inner = m[2];
        var title = (/title=["']([^"']+)["']/i.exec(m[0]) || /alt=["']([^"']+)["']/i.exec(inner) || [])[1] || stripHtml(inner);
        title = stripHtml(title);
        if (!title) continue;
        seen[href] = true;
        var pic = (/(?:data-original|data-src|src)=["']([^"']+)["']/i.exec(inner) || [])[1] || '';
        out.push({ vod_id: href, vod_name: title, vod_pic: safePic(pic, wnHost + '/'), vod_remarks: '' });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' }, { type_id: '2', type_name: '连续剧' },
          { type_id: '3', type_name: '综艺' }, { type_id: '4', type_name: '动漫' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return { list: wnCards(httpReq(wnHost + '/', { headers: wnHeaders }).body) }; };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? ('/vodtype/' + str(tid) + '-' + page + '/') : ('/vodtype/' + str(tid) + '/');
      var list = wnCards(httpReq(wnHost + path, { headers: wnHeaders }).body);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var list = wnCards(httpReq(wnHost + '/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---/', { headers: wnHeaders }).body);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), wnHost + '/').url, { headers: wnHeaders }).body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, 'img.lazyload&&data-original') || pdfh(html, 'img&&src'), wnHost + '/'),
          vod_content: stripHtml(pdfh(html, '.vod_content&&Text') || pdfh(html, '.content&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 7: wexpianku-v1 (AiNewPianKu)
  // =========================================================================
  if (cfg.adapter === 'wexpianku-v1') {
    var pkHost = pickSiteHosts([str(cfg.siteKey), str(cfg.siteKeyAlt)], [cfg.defaultHost])[0];
    var pkHeaders = { 'User-Agent': ua, Referer: pkHost + '/' };
    function pkCards(html) {
      var items = pdfa(html, '.vod-item, .module-item');
      var out = [], seen = {};
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var href = pdfh(it, 'a[href*="/voddetail/"]&&href') || pdfh(it, 'a&&href');
        if (!href || seen[href]) continue;
        var name = stripHtml(pdfh(it, 'a&&title') || pdfh(it, 'img&&alt') || pdfh(it, '.vod-name&&Text'));
        if (!name) continue;
        seen[href] = true;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(it, 'img&&data-original') || pdfh(it, 'img&&data-src') || pdfh(it, 'img&&src'), pkHost + '/'),
          vod_remarks: stripHtml(pdfh(it, '.vod-remarks&&Text'))
        });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '20', type_name: '电影' }, { type_id: '37', type_name: '剧集' },
          { type_id: '43', type_name: '动漫' }, { type_id: '45', type_name: '综艺' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return { list: pkCards(httpReq(pkHost + '/', { headers: pkHeaders }).body) }; };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var list = pkCards(httpReq(pkHost + '/vodtype/' + str(tid) + '-' + page + '.html', { headers: pkHeaders }).body);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var list = pkCards(httpReq(pkHost + '/vodsearch/-------------.html?wd=' + encodeURIComponent(kw), { headers: pkHeaders }).body);
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var detailUrl = address(str(vid), pkHost + '/').url;
      var html = httpReq(detailUrl, { headers: pkHeaders }).body;
      var shares = extractSharesFromHtml(html);
      var numM = /(\d+)/.exec(str(vid));
      if (numM && str(cfg.fetchApiPath)) {
        var sseRes = httpReqSoft(pkHost + str(cfg.fetchApiPath) + numM[1], { headers: pkHeaders, timeout: 8000 });
        if (sseRes && str(sseRes.body)) {
          var lines = str(sseRes.body).split(/\r?\n/);
          var openCount = 0;
          for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (ln.indexOf('data:') !== 0) continue;
            var obj = parseJsonSafe(ln.slice(5));
            var item = isObj(obj) && isObj(obj.item) ? obj.item : obj;
            if (!isObj(item) || !str(item.link)) continue;
            var lnk = str(item.link).trim();
            var pwd = str(item.password || item.pwd).trim();
            if (str(cfg.openApiPath) && lnk.indexOf(str(cfg.openApiPath)) >= 0 && openCount < 8) {
              openCount++;
              var openFull = address(lnk, pkHost + '/').url;
              var opRes = httpReqSoft(openFull + (openFull.indexOf('?') >= 0 ? '&' : '?') + 'json=1', { headers: pkHeaders, timeout: 5000 });
              var opJson = opRes ? parseJsonSafe(opRes.body) : null;
              if (isObj(opJson) && str(opJson.url)) {
                lnk = str(opJson.url);
                pwd = str(opJson.password || pwd);
              }
            }
            if (isSupportedCloudShare(lnk)) {
              shares.push({ url: lnk, pwd: pwd, label: str(item.title || item.name) });
            }
          }
        }
      }
      var tabs = groupShareTabs(shares);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.vod-pic img&&src') || pdfh(html, 'img&&src'), pkHost + '/'),
          vod_content: stripHtml(pdfh(html, '.vod-desc&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 8: wexqiwei-v1 (AiQwMkv)
  // =========================================================================
  if (cfg.adapter === 'wexqiwei-v1') {
    var qwHost = pickSiteHosts(str(cfg.siteKey || 'qiwei'), [cfg.defaultHost])[0];
    var qwHeaders = { 'User-Agent': ua, Referer: qwHost + '/' };
    function qwCards(html) {
      var rows = pdfa(html, 'ul.content-list > li, .content-list li');
      var out = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var href = pdfh(r, 'a&&href');
        var name = stripHtml(pdfh(r, 'a&&title') || pdfh(r, 'img&&alt') || pdfh(r, 'h3&&Text'));
        if (!href || !name) continue;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(r, 'img&&data-original') || pdfh(r, 'img&&src'), qwHost + '/'),
          vod_remarks: stripHtml(pdfh(r, '.bottom&&Text'))
        });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' }, { type_id: '2', type_name: '剧集' },
          { type_id: '3', type_name: '综艺' }, { type_id: '4', type_name: '动漫' },
          { type_id: '30', type_name: '短剧' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return { list: qwCards(httpReq(qwHost + '/', { headers: qwHeaders }).body) }; };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var list = qwCards(httpReq(qwHost + '/vt/' + str(tid) + '-' + page + '.html', { headers: qwHeaders }).body);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var sug = httpReqSoft(qwHost + '/index.php/ajax/suggest?mid=1&limit=30&wd=' + encodeURIComponent(kw), { headers: qwHeaders });
      var doc = sug ? parseJsonSafe(sug.body) : null;
      var list = [];
      if (isObj(doc) && Array.isArray(doc.list)) {
        list = doc.list.map(function (it) {
          if (!isObj(it) || !it.id || !it.name) return null;
          return { vod_id: '/mv/' + it.id + '.html', vod_name: str(it.name), vod_pic: safePic(it.pic, qwHost + '/'), vod_remarks: '' };
        }).filter(Boolean);
      }
      return { page: 1, pagecount: 1, limit: 30, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), qwHost + '/').url, { headers: qwHeaders }).body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      var froms = tabs.froms.slice(), urls = tabs.urls.slice();
      var pyTabs = pdfa(html, '#url .py-tabs li');
      var pyLists = pdfa(html, '#url .bd ul.player');
      for (var i = 0; i < pyLists.length; i++) {
        var links = pdfa(pyLists[i], 'a[href]');
        var eps = [];
        for (var j = 0; j < links.length; j++) {
          var href = pdfh(links[j], 'a&&href');
          var epN = stripHtml(links[j]) || ('第' + (j + 1) + '集');
          if (href) eps.push(epN.replace(/[$#]/g, ' ') + '$qwplay:' + href);
        }
        if (eps.length) {
          froms.push(stripHtml(pyTabs[i] || ('在线' + (i + 1))));
          urls.push(eps.join('#'));
        }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, '.main-ui-meta h1&&Text') || pdfh(html, 'h1&&Text')),
          vod_pic: safePic(pdfh(html, '.imgblock img&&src') || pdfh(html, 'img&&src'), qwHost + '/'),
          vod_content: stripHtml(pdfh(html, '.zkjj_a&&Text') || pdfh(html, '.sqjj_a&&Text')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var s = str(id).trim();
      if (s.indexOf('qwplay:') === 0) {
        var html = httpReq(address(s.slice(7), qwHost + '/').url, { headers: qwHeaders }).body;
        var m = /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</i.exec(html);
        var pj = m ? parseJsonSafe(m[1]) : null;
        if (isObj(pj) && str(pj.url)) {
          var u = str(pj.url);
          if (Number(pj.encrypt) === 1) u = unescape(u);
          else if (Number(pj.encrypt) === 2) u = unescape(b64ToUtf8(u));
          if (/^https?:\/\//i.test(u)) return { parse: 0, url: address(u).url, header: qwHeaders };
        }
      }
      return defaultPlay(flag, id);
    };
    return;
  }

  // =========================================================================
  // Group 9: wexyidong-v1 (AiNewYiDong4K)
  // =========================================================================
  if (cfg.adapter === 'wexyidong-v1') {
    var ydHeaders = {
      'User-Agent': ua,
      'Content-Type': 'application/json;charset=UTF-8',
      Origin: str(cfg.originUrl),
      Referer: str(cfg.refererUrl)
    };
    function ydPost(endpoint, payload) {
      var r = httpReq(str(cfg.apiBase) + endpoint, { method: 'POST', headers: ydHeaders, body: JSON.stringify(payload) });
      var doc = parseJsonSafe(r.body);
      if (!isObj(doc)) fail('drpy_source_response');
      return isObj(doc.data) ? doc.data : doc;
    }
    function ydCard(it) {
      if (!isObj(it) || !it.id || !it.title) return null;
      return {
        vod_id: str(it.id),
        vod_name: str(it.title),
        vod_pic: safePic(it.appCoverUrl || it.pcCoverUrl, str(cfg.originUrl) + '/'),
        vod_remarks: str(it.score || it.updateTime || '')
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '动漫' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var d = ydPost('qryPageColumnVideo', { columnId: 1, cateIdList: [], pageIndex: 1, pageSize: 12, searchKey: '' });
      var arr = Array.isArray(d.list) ? d.list : [];
      return { list: arr.map(ydCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var d = ydPost('qryPageColumnVideo', { columnId: Number(tid) || 1, cateIdList: [], pageIndex: page, pageSize: 12, searchKey: '' });
      var list = (Array.isArray(d.list) ? d.list : []).map(ydCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 9 ? page + 1 : page, limit: 12, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 12, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = ydPost('qryPageColumnVideo', { columnId: 0, cateIdList: [], pageIndex: page, pageSize: 12, searchKey: kw });
      var list = (Array.isArray(d.list) ? d.list : []).map(ydCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 9 ? page + 1 : page, limit: 12, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = ydPost('qryVideoDetail', { videoId: str(vid), fprint: randomHex(32) });
      var shares = [];
      if (isSupportedCloudShare(d.resUrl)) shares.push({ url: str(d.resUrl), pwd: str(d.resPwd || ''), label: str(d.title) });
      var tabs = groupShareTabs(shares);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.title),
          vod_pic: safePic(d.appCoverUrl || d.pcCoverUrl, str(cfg.originUrl) + '/'),
          vod_content: stripHtml(d.videoDesc || d.intro),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  // =========================================================================
  // Group 10: 4 Search-Only Pan Spiders
  // =========================================================================
  if (cfg.adapter === 'wexaipanso-v1') {
    var apBase = str(cfg.defaultHost).replace(/\/+$/, '');
    var apHeaders = { 'User-Agent': ua, Referer: apBase + '/' };
    __drpy.home = function () { return { class: [], filters: {} }; };
    __drpy.homeVod = function () { return { list: [] }; };
    __drpy.category = function () { return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] }; };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var html = httpReq(str(cfg.searchUrlPrefix) + encodeURIComponent(kw) + '&p=all&page=' + page, { headers: apHeaders }).body;
      var rows = pdfa(html, 'van-row');
      var list = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var href = pdfh(r, 'a[href^="/s/"]&&href');
        if (!href) continue;
        var title = stripHtml(pdfh(r, '[name="content-title"]&&Text') || pdfh(r, 'a&&Text'));
        if (!title) continue;
        list.push({
          vod_id: encodeShareId({ href: href, title: title }),
          vod_name: title,
          vod_pic: '',
          vod_remarks: '网盘搜索'
        });
      }
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var info = decodeShareId(vid);
      var slug = str(info.href).split('/').pop();
      var cvTarget = str(cfg.cvUrlPrefix) + slug;
      var shares = [];
      var r = httpReqSoft(cvTarget, { headers: apHeaders, redirect: 0, timeout: 8000 });
      var loc = r && r.headers ? str(r.headers.location || r.headers.Location) : '';
      if (isSupportedCloudShare(loc)) {
        shares.push({ url: loc, pwd: '', label: info.title });
      } else {
        var r2 = httpReqSoft(cvTarget, { headers: apHeaders, timeout: 8000 });
        if (r2 && str(r2.body)) shares = extractSharesFromHtml(r2.body);
      }
      var tabs = groupShareTabs(shares);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(info.title || '网盘资源'),
          vod_pic: '',
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  if (cfg.adapter === 'wexhaiyin-v1' || cfg.adapter === 'wexquanpan-v1') {
    __drpy.home = function () { return { class: [], filters: {} }; };
    __drpy.homeVod = function () { return { list: [] }; };
    __drpy.category = function () { return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] }; };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 30, total: 0, list: [] };
      var merged = null;
      if (cfg.adapter === 'wexhaiyin-v1') {
        var hyHosts = pickSiteHosts('', [cfg.defaultHost, cfg.site0, cfg.site1, cfg.site2, cfg.site3, cfg.site4]);
        for (var i = 0; i < hyHosts.length; i++) {
          var r = httpReqSoft(hyHosts[i] + str(cfg.searchApiPath) + encodeURIComponent(kw), { headers: { 'User-Agent': ua }, timeout: 6000 });
          var j = r ? parseJsonSafe(r.body) : null;
          if (isObj(j) && isObj(j.data) && isObj(j.data.merged_by_type)) { merged = j.data.merged_by_type; break; }
        }
      } else {
        var qpHeaders = { 'User-Agent': ua, Referer: str(cfg.refererUrl), Origin: str(cfg.defaultHost).replace(/\/+$/, ''), 'Content-Type': 'application/json' };
        var tr = httpReqSoft(str(cfg.tokenUrl), { headers: qpHeaders, timeout: 5000 });
        var tj = tr ? parseJsonSafe(tr.body) : null;
        var tok = isObj(tj) ? str(tj.token || (isObj(tj.data) && tj.data.token)) : '';
        if (tok) qpHeaders['X-QP-K'] = tok;
        var sr = httpReqSoft(str(cfg.searchApiUrl), { method: 'POST', headers: qpHeaders, body: JSON.stringify({ kw: kw, res: 'merge', src: 'all' }), timeout: 8000 });
        var sj = sr ? parseJsonSafe(sr.body) : null;
        if (isObj(sj) && isObj(sj.data) && isObj(sj.data.merged_by_type)) merged = sj.data.merged_by_type;
      }
      var list = [];
      if (isObj(merged)) {
        var types = Object.keys(merged);
        for (var t = 0; t < types.length; t++) {
          var arr = Array.isArray(merged[types[t]]) ? merged[types[t]] : [];
          for (var k = 0; k < arr.length; k++) {
            var it = arr[k];
            var u = str(it && it.url).trim();
            if (!isSupportedCloudShare(u)) continue;
            var title = stripHtml(it.note || it.title || kw);
            var prov = panProviderName(u);
            list.push({
              vod_id: encodeShareId({ title: title, url: u, pwd: str(it.password || it.pwd) }),
              vod_name: title,
              vod_pic: '',
              vod_remarks: prov
            });
          }
        }
      }
      return { page: 1, pagecount: 1, limit: 50, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var info = decodeShareId(vid);
      var tabs = groupShareTabs([{ url: info.url, pwd: info.pwd, label: info.title }]);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(info.title || '网盘资源'),
          vod_pic: '',
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  if (cfg.adapter === 'wexkaka-v1') {
    var kkBase = str(cfg.defaultHost).replace(/\/+$/, '');
    __drpy.home = function () { return { class: [], filters: {} }; };
    __drpy.homeVod = function () { return { list: [] }; };
    __drpy.category = function () { return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] }; };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 30, total: 0, list: [] };
      var r = httpReq(str(cfg.searchApiPrefix) + encodeURIComponent(kw) + str(cfg.searchApiSuffix), {
        headers: { 'User-Agent': ua, Referer: kkBase + '/search?q=' + encodeURIComponent(kw) }
      });
      var doc = parseJsonSafe(r.body);
      var arr = isObj(doc) && isObj(doc.data) && Array.isArray(doc.data.results) ? doc.data.results :
                (isObj(doc) && Array.isArray(doc.results) ? doc.results : []);
      var list = [];
      for (var i = 0; i < arr.length; i++) {
        var row = arr[i];
        if (!isObj(row)) continue;
        var title = stripHtml(row.title || row.name || kw);
        var links = Array.isArray(row.links) ? row.links : (str(row.first_url || row.url) ? [{ url: row.first_url || row.url }] : []);
        if (!links.length) continue;
        list.push({
          vod_id: encodeShareId({ title: title, links: links }),
          vod_name: title,
          vod_pic: '',
          vod_remarks: str(row.cloud_type || '网盘')
        });
      }
      return { page: 1, pagecount: 1, limit: 30, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var info = decodeShareId(vid);
      var links = Array.isArray(info.links) ? info.links : [];
      var shares = [];
      for (var i = 0; i < links.length; i++) {
        var lk = isObj(links[i]) ? str(links[i].url || links[i].link) : str(links[i]);
        var pwd = isObj(links[i]) ? str(links[i].pwd || links[i].password) : '';
        if (!lk) continue;
        if (!isSupportedCloudShare(lk) && (lk.indexOf('/api/wash') >= 0 || (str(cfg.washApiUrl) && lk.indexOf(str(cfg.washApiUrl)) === 0))) {
          var fullWash = address(lk, kkBase + '/').url;
          var wr = httpReqSoft(fullWash, { headers: { 'User-Agent': ua, Referer: kkBase + '/search' }, timeout: 6000 });
          var wj = wr ? parseJsonSafe(wr.body) : null;
          if (isObj(wj)) lk = str(wj.raw_url || (isObj(wj.data) && wj.data.raw_url) || lk);
        }
        if (isSupportedCloudShare(lk)) shares.push({ url: lk, pwd: pwd, label: info.title });
      }
      var tabs = groupShareTabs(shares);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(info.title || '网盘资源'),
          vod_pic: '',
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = defaultPlay;
    return;
  }

  fail('drpy_source_unavailable');
}

module.exports = function wexPanRule(config) {
  if (!config || !PAN_WEX_ADAPTERS.includes(config.adapter) || !/^https?:\/\//.test(config.origin)) {
    throw Error('endpoint configuration required');
  }
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:12000,预处理:"js:rule._install();",_install:' + installWexPan.toString() + '};';
};

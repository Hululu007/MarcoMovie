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
  var lastSoftChallenge = false;
  function hasVodMarkup(t) {
    return /(?:\/voddetail\/|\/vodplay\/|\/vod\/detail\/|module-item|vod-item|vodlist|myui-vodlist|stui-vodlist|video-info|content-list|posts-item|"vod_id"\s*:|pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|aliyundrive\.com|alipan\.com)/i.test(t);
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
  function isDeadMirrorBody(body) {
    var head = str(body).slice(0, 4096);
    return /<title>\s*(?:再见[，,\s]*我们跑路了|网站已关闭|站点已关闭|Welcome to nginx!|404 Not Found)\s*<\/title>/i.test(head);
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
    var code = (res && res.code) || 0;
    checkChallenge(body, code);
    return { body: body, headers: (res && res.headers) || {}, code: code };
  }
  function httpReqSoft(url, opts) {
    lastSoftChallenge = false;
    try {
      var target = address(url).url;
      var o = Object.assign({ timeout: 6000 }, opts || {});
      if (o.headers) o.headers = cleanHeaders(o.headers);
      var res = req(target, o);
      if (!res || typeof res.content !== 'string') return null;
      var code = res.code || 0;
      if (isChallengeBody(res.content, code)) {
        lastSoftChallenge = true;
        return null;
      }
      return { body: res.content, headers: res.headers || {}, code: code };
    } catch (_) {
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
  var memRemoteCfg = null;
  var memRemoteTriedAt = 0;
  function loadRemoteWexConfig() {
    if (memRemoteCfg && (str(memRemoteCfg.siteUrl) || (isObj(memRemoteCfg.siteConfig) && Object.keys(memRemoteCfg.siteConfig).length))) {
      return memRemoteCfg;
    }
    var cached = local.get('wex-remote', 'cfg_v1');
    if (isObj(cached) && Number(cached.exp) > Date.now() && (str(cached.siteUrl) || (isObj(cached.siteConfig) && Object.keys(cached.siteConfig).length))) {
      memRemoteCfg = cached;
      return cached;
    }
    if (memRemoteTriedAt && Date.now() - memRemoteTriedAt < 3 * 60 * 1000) {
      return { siteUrl: '', mySiteUrl: '', siteConfig: {}, exp: 0 };
    }
    memRemoteTriedAt = Date.now();
    var startedAt = Date.now();
    var rHeaders = { 'User-Agent': str(cfg.remoteUa || cfg.userAgent || 'Mozilla/5.0'), Accept: 'application/json,text/plain,*/*' };
    var siteUrl = '';
    var siteConfig = {};
    var itemUrls = [cfg.itemTxt0, cfg.itemTxt1, cfg.itemTxt2].map(str).filter(Boolean);
    for (var j = 0; j < itemUrls.length; j++) {
      if (Date.now() - startedAt > 4500) break;
      var ir = httpReqSoft(itemUrls[j], { headers: rHeaders, timeout: 1800 });
      if (ir && ir.code >= 200 && ir.code < 300) {
        var itemObj = parseJsonSafe(decryptRemoteText(ir.body));
        if (isObj(itemObj)) {
          var csUrl = str(itemObj.config_site).trim();
          if (/^https?:\/\//i.test(csUrl) && Date.now() - startedAt <= 4500) {
            var sr = httpReqSoft(csUrl, { headers: rHeaders, timeout: 2200 });
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
    if (siteUrl || Object.keys(siteConfig).length) {
      memRemoteCfg = out;
      local.set('wex-remote', 'cfg_v1', out);
    }
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
  function expandHostCandidates(hosts) {
    var out = [], seen = Object.create(null);
    function add(h) {
      var v = str(h).trim().replace(/\/+$/, '');
      if (/^https?:\/\/[^/?#@]+$/i.test(v) && !seen[v]) { seen[v] = 1; out.push(v); }
    }
    var arr = Array.isArray(hosts) ? hosts : [];
    for (var i = 0; i < arr.length; i++) {
      add(arr[i]);
      var hm = /^(https?:)\/\/([^/?#:]+)(:\d+)?(?:[/?#]|$)/i.exec(str(arr[i]).trim());
      if (hm) {
        var proto = hm[1];
        var host = hm[2];
        var portPart = hm[3] || '';
        if (host.indexOf('www.') === 0) {
          add(proto + '//' + host.slice(4) + portPart);
        } else if (!/^\d+\.\d+\.\d+\.\d+$/.test(host) && host.indexOf(':') < 0 && host.split('.').length === 2) {
          add(proto + '//www.' + host + portPart);
        }
      }
    }
    return out;
  }
  function reqFromHosts(state, pathOrUrl, opts) {
    var list = state.getHosts();
    var p = str(pathOrUrl).trim();
    var relPath = '';
    if (/^https?:\/\//i.test(p)) {
      relPath = p.replace(/^https?:\/\/[^/?#]+/i, '').split('#')[0] || '/';
    } else {
      relPath = p.charAt(0) === '/' ? p : ('/' + p);
    }
    var order = [];
    if (state.current) order.push(state.current);
    for (var i = 0; i < list.length; i++) {
      if (order.indexOf(list[i]) < 0) order.push(list[i]);
    }
    var requestedTimeout = (opts && opts.timeout) || 6500;
    var perHostCap = order.length > 2 ? 2800 : (order.length > 1 ? 4000 : 6500);
    var deadline = Date.now() + 9500;
    var sawChallenge = false;
    for (var j = 0; j < order.length; j++) {
      var rem = deadline - Date.now();
      if (rem < 900) break;
      var h = order[j];
      var target = (/^https?:\/\//i.test(p) && j === 0 && p.indexOf(h) === 0) ? p : (h + relPath);
      var hdrs = Object.assign({ 'User-Agent': ua, Referer: h + '/' }, (opts && opts.headers) || {});
      var attemptTimeout = Math.min(requestedTimeout, perHostCap, rem);
      var r = httpReqSoft(target, Object.assign({}, opts || {}, { headers: hdrs, timeout: attemptTimeout }));
      if (lastSoftChallenge) sawChallenge = true;
      if (r && r.code >= 200 && r.code < 400 && str(r.body) && !isDeadMirrorBody(r.body)) {
        state.current = h;
        return { host: h, body: r.body, headers: r.headers, code: r.code };
      }
    }
    fail(sawChallenge ? 'drpy_verification_required' : 'drpy_source_unavailable');
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
    var mpHostList = null;
    var mpState = {
      current: '',
      getHosts: function () {
        if (!mpHostList) {
          mpHostList = expandHostCandidates(pickSiteHosts(str(cfg.siteKey), [cfg.defaultHost]));
          if (!mpState.current && mpHostList.length) mpState.current = mpHostList[0];
        }
        return mpHostList;
      }
    };
    var lastRootHtml = '';
    var lastRootAt = 0;
    function mpHtml(path) {
      if (path === '/' && lastRootHtml && Date.now() - lastRootAt < 30000) return lastRootHtml;
      var res = reqFromHosts(mpState, path, { timeout: 8500 });
      if (path === '/') {
        lastRootHtml = res.body;
        lastRootAt = Date.now();
      }
      return res.body;
    }
    function mpParseCardsRegex(html) {
      var out = [], seen = {};
      var re = /<a[^>]+href=["']([^"']*\/(?:index\.php\/)?vod\/detail\/(?:id\/)?[^"']+)["'][^>]*>([\s\S]{1,1200}?)<\/a>/gi, m;
      while ((m = re.exec(html)) !== null && out.length < 80) {
        var href = m[1];
        if (!href || seen[href]) continue;
        var fullTag = m[0];
        var inner = m[2];
        var tM = /\btitle=["']([^"']+)["']/i.exec(fullTag) || /\balt=["']([^"']+)["']/i.exec(inner);
        var name = stripHtml((tM && tM[1]) || inner);
        if (!name || name.length > 80) continue;
        seen[href] = true;
        var pM = /(?:data-original|data-src|src)=["']([^"']+)["']/i.exec(inner);
        var rM = /class=["'][^"']*(?:module-item-text|video-serial|pic-text)[^"']*["'][^>]*>([\s\S]*?)<\//i.exec(inner);
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic((pM && pM[1]) || '', mpState.current + '/'),
          vod_remarks: stripHtml((rM && rM[1]) || '')
        });
      }
      return out;
    }
    function mpParseCards(html) {
      var text = str(html);
      if (text.length > 150000) {
        var fast = mpParseCardsRegex(text);
        if (fast.length) return fast;
      }
      var cards = pdfa(text, '.module-search-item, .module-item');
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
          vod_pic: safePic(pdfh(c, 'img&&data-src') || pdfh(c, 'img&&data-original') || pdfh(c, 'img&&src'), mpState.current + '/'),
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
      var headChunk = html.slice(0, 120000);
      var classes = [], seen = {};
      var navRe = /<a[^>]+href=["']([^"']*(?:\/vod\/type\/id\/|\/vod\/show\/id\/|\/vodshow\/)[^"']*)["'][^>]*>([\s\S]{1,120}?)<\/a>/gi, nmM;
      while ((nmM = navRe.exec(headChunk)) !== null) {
        var mId = /(?:\/id\/|\/vodshow\/)(\d+)/i.exec(nmM[1]);
        var nmTxt = stripHtml(nmM[2]);
        if (mId && nmTxt && nmTxt.length <= 10 && !seen[mId[1]]) {
          seen[mId[1]] = true;
          classes.push({ type_id: mId[1], type_name: nmTxt });
        }
      }
      if (!classes.length) {
        var navs = pdfa(html, 'a[href*="/vod/type/id/"], a[href*="/vod/show/id/"], a[href*="/vodshow/"]');
        for (var i = 0; i < navs.length; i++) {
          var href = pdfh(navs[i], 'a&&href');
          var m = /(?:\/id\/|\/vodshow\/)(\d+)/i.exec(href);
          var nm = stripHtml(navs[i]);
          if (m && nm && nm.length <= 10 && !seen[m[1]]) {
            seen[m[1]] = true;
            classes.push({ type_id: m[1], type_name: nm });
          }
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
      mpState.getHosts();
      if (cfg.adapter === 'wexhuajuan-v1' && page === 1) {
        var sug = httpReqSoft(mpState.current + '/index.php/ajax/suggest?mid=1&wd=' + encodeURIComponent(kw) + '&limit=50', { headers: { 'User-Agent': ua, Referer: mpState.current + '/' } });
        var sj = sug ? parseJsonSafe(sug.body) : null;
        if (isObj(sj) && Array.isArray(sj.list) && sj.list.length) {
          var sList = sj.list.map(function (it) {
            if (!isObj(it) || !it.id || !it.name) return null;
            return { vod_id: '/index.php/vod/detail/id/' + it.id + '.html', vod_name: str(it.name), vod_pic: safePic(it.pic, mpState.current + '/'), vod_remarks: '' };
          }).filter(Boolean);
          if (sList.length) return { page: 1, pagecount: 1, limit: 50, total: sList.length, list: sList };
        }
      }
      var paths = cfg.adapter === 'wexwogg-v1'
        ? ['/index.php/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---.html']
        : ['/index.php/vod/search/page/' + page + '/wd/' + encodeURIComponent(kw) + '.html', '/index.php/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---.html'];
      var list = [];
      for (var i = 0; i < paths.length && !list.length; i++) {
        try {
          var sr = reqFromHosts(mpState, paths[i], { timeout: 8500 });
          if (sr && str(sr.body)) list = mpParseCards(sr.body);
        } catch (_) {}
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
          vod_pic: safePic(pdfh(html, '.module-item-pic img&&data-src') || pdfh(html, '.lazyload&&data-src') || pdfh(html, 'img&&src'), mpState.current + '/'),
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
    var jtHostList = null;
    var jtState = {
      current: '',
      getHosts: function () {
        if (!jtHostList) {
          jtHostList = expandHostCandidates(pickSiteHosts(str(cfg.siteKey || 'jutou'), [cfg.defaultHost]));
          if (!jtState.current && jtHostList.length) jtState.current = jtHostList[0];
        }
        return jtHostList;
      }
    };
    function jtCards(html, host) {
      var base = (host || jtState.current) + '/';
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
          vod_pic: safePic(pdfh(r, 'img&&data-src') || pdfh(r, 'img&&src'), base),
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
    __drpy.homeVod = function () {
      var res = reqFromHosts(jtState, '/');
      return { list: jtCards(res.body, res.host) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? ('/' + str(tid) + '_' + page + '/') : ('/' + str(tid) + '/');
      var res = reqFromHosts(jtState, path);
      var list = jtCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var res = reqFromHosts(jtState, '/search/?keyword=' + encodeURIComponent(kw) + '&page=' + page);
      var list = jtCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var res = reqFromHosts(jtState, str(vid));
      var html = res.body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'main article h1&&Text') || pdfh(html, 'h1&&Text')),
          vod_pic: safePic(pdfh(html, 'article img&&src'), res.host + '/'),
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
    var znHostList = null;
    var znState = {
      current: '',
      getHosts: function () {
        if (!znHostList) {
          znHostList = expandHostCandidates(pickSiteHosts('', [cfg.defaultHost]));
          if (!znState.current && znHostList.length) znState.current = znHostList[0];
        }
        return znHostList;
      }
    };
    function znCards(html, host) {
      var base = (host || znState.current) + '/';
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
          vod_pic: safePic(pdfh(r, 'img&&data-src') || pdfh(r, 'img&&src'), base),
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
    __drpy.homeVod = function () {
      var res = reqFromHosts(znState, '/books/zuixin');
      return { list: znCards(res.body, res.host) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? (str(tid) + '/page/' + page) : str(tid);
      var res = reqFromHosts(znState, path);
      var list = znCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var path = (page > 1 ? ('/page/' + page) : '') + '/?post_type=book&s=' + encodeURIComponent(kw);
      var res = reqFromHosts(znState, path);
      var list = znCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var res = reqFromHosts(znState, str(vid));
      var html = res.body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.book-cover img&&data-src') || pdfh(html, '.book-cover img&&src'), res.host + '/'),
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
    var wnHostList = null;
    var wnState = {
      current: '',
      getHosts: function () {
        if (!wnHostList) {
          wnHostList = expandHostCandidates(pickSiteHosts(str(cfg.siteKey || 'woniu4k'), [cfg.defaultHost]));
          if (!wnState.current && wnHostList.length) wnState.current = wnHostList[0];
        }
        return wnHostList;
      }
    };
    function wnCards(html, host) {
      var base = (host || wnState.current) + '/';
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
        out.push({ vod_id: href, vod_name: title, vod_pic: safePic(pic, base), vod_remarks: '' });
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
    __drpy.homeVod = function () {
      var res = reqFromHosts(wnState, '/');
      return { list: wnCards(res.body, res.host) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = page > 1 ? ('/vodtype/' + str(tid) + '-' + page + '/') : ('/vodtype/' + str(tid) + '/');
      var res = reqFromHosts(wnState, path);
      var list = wnCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var res = reqFromHosts(wnState, '/vodsearch/' + encodeURIComponent(kw) + '----------' + page + '---/');
      var list = wnCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var res = reqFromHosts(wnState, str(vid));
      var html = res.body;
      var tabs = groupShareTabs(extractSharesFromHtml(html));
      if (!tabs.urls.length && /(?:pan-lock-box|网盘资源已锁定|登录后可查看完整网盘链接)/.test(html)) {
        fail('drpy_authentication_required');
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, '.premium-title&&Text') || pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.premium-poster img&&data-src') || pdfh(html, '.premium-poster img&&src') || pdfh(html, 'img.lazyload&&data-original') || pdfh(html, 'img&&src'), res.host + '/'),
          vod_content: stripHtml(pdfh(html, '#detailDescText&&Text') || pdfh(html, '.vod_content&&Text') || pdfh(html, '.content&&Text')),
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
    var pkHostList = null;
    var pkState = {
      current: '',
      getHosts: function () {
        if (!pkHostList) {
          pkHostList = expandHostCandidates(pickSiteHosts([str(cfg.siteKey), str(cfg.siteKeyAlt)], [cfg.defaultHost]));
          if (!pkState.current && pkHostList.length) pkState.current = pkHostList[0];
        }
        return pkHostList;
      }
    };
    function pkCards(html, host) {
      var base = (host || pkState.current) + '/';
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
          vod_pic: safePic(pdfh(it, 'img&&data-original') || pdfh(it, 'img&&data-src') || pdfh(it, 'img&&src'), base),
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
    __drpy.homeVod = function () {
      var res = reqFromHosts(pkState, '/');
      return { list: pkCards(res.body, res.host) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var res = reqFromHosts(pkState, '/vodtype/' + str(tid) + '-' + page + '.html');
      var list = pkCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var res = reqFromHosts(pkState, '/vodsearch/-------------.html?wd=' + encodeURIComponent(kw));
      var list = pkCards(res.body, res.host);
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var res = reqFromHosts(pkState, str(vid));
      var html = res.body;
      var activeHost = res.host;
      var pkHeaders = { 'User-Agent': ua, Referer: activeHost + '/' };
      var shares = extractSharesFromHtml(html);
      var sseNeedVerify = false;
      var numM = /(\d+)/.exec(str(vid));
      if (numM && str(cfg.fetchApiPath)) {
        var sseRes = httpReqSoft(activeHost + str(cfg.fetchApiPath) + numM[1], { headers: pkHeaders, timeout: 5000 });
        if (sseRes && str(sseRes.body)) {
          var lines = str(sseRes.body).split(/\r?\n/);
          var openCount = 0;
          for (var i = 0; i < lines.length; i++) {
            var ln = lines[i].trim();
            if (ln.indexOf('data:') !== 0) continue;
            var obj = parseJsonSafe(ln.slice(5));
            if (isObj(obj) && str(obj.type) === 'error' && /(?:人机验证|验证码|turnstile)/i.test(str(obj.message))) {
              sseNeedVerify = true;
              continue;
            }
            var item = isObj(obj) && isObj(obj.item) ? obj.item : obj;
            if (!isObj(item) || !str(item.link)) continue;
            var lnk = str(item.link).trim();
            var pwd = str(item.password || item.pwd).trim();
            if (str(cfg.openApiPath) && lnk.indexOf(str(cfg.openApiPath)) >= 0 && openCount < 8) {
              openCount++;
              var openFull = address(lnk, activeHost + '/').url;
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
      var tabMap = Object.create(null);
      var tabOrder = [];
      var tabRe = /<span[^>]*class=["'][^"']*source-tab-item[^"']*["'][^>]*data-target=["']([^"']+)["'][^>]*>([\s\S]*?)<\/span>/gi, tm;
      while ((tm = tabRe.exec(html)) !== null) {
        var tId = str(tm[1]).trim();
        var tName = stripHtml(tm[2]).replace(/[$#]/g, ' ').trim();
        if (!tId || !tName || /^(?:优酷|奇异|爱奇艺|腾讯|腾讯视频|芒果|芒果TV|B站|哔哩哔哩|bilibili|搜狐|乐视|PPTV)$/i.test(tName)) continue;
        tabMap[tId] = tName;
        tabOrder.push(tId);
      }
      if (tabOrder.length) {
        var paneMap = Object.create(null);
        var panes = pdfa(html, 'div.source-pane');
        for (var pi = 0; pi < panes.length; pi++) {
          var paneHtml = panes[pi];
          var pidM = /\bid=["']([^"']+)["']/i.exec(paneHtml);
          if (!pidM || !tabMap[pidM[1]]) continue;
          var eps = [];
          var epRe = /<a[^>]+href=["']([^"']*\/vodplay\/[^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, em;
          while ((em = epRe.exec(paneHtml)) !== null) {
            var epHref = str(em[1]).trim();
            var epLabel = stripHtml(em[2]).replace(/[$#]/g, ' ').trim() || ('第' + (eps.length + 1) + '集');
            eps.push(epLabel + '$' + epHref);
          }
          if (eps.length) paneMap[pidM[1]] = eps.join('#');
        }
        for (var ti = 0; ti < tabOrder.length; ti++) {
          var targetId = tabOrder[ti];
          if (paneMap[targetId]) {
            tabs.froms.push(tabMap[targetId]);
            tabs.urls.push(paneMap[targetId]);
          }
        }
      }
      if (!tabs.froms.length && sseNeedVerify) {
        fail('drpy_verification_required');
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.vod-pic img&&src') || pdfh(html, 'img&&src'), activeHost + '/'),
          vod_content: stripHtml(pdfh(html, '.vod-desc&&Text')),
          vod_play_from: tabs.froms.join('$$$'),
          vod_play_url: tabs.urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var s = str(id).trim();
      if (s.indexOf('mmshare://') === 0 || isSupportedCloudShare(s)) return defaultPlay(flag, id);
      if (/^(?:https?:\/\/[^/?#]+)?\/vodplay\//i.test(s)) {
        var playPath = s.replace(/^https?:\/\/[^/?#]+/i, '');
        var playRes = reqFromHosts(pkState, playPath);
        var pm = /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</i.exec(str(playRes.body));
        var pObj = pm ? parseJsonSafe(pm[1]) : null;
        var pUrl = isObj(pObj) ? str(pObj.url).trim() : '';
        var enc = isObj(pObj) ? Number(pObj.encrypt || 0) : 0;
        if (pUrl && enc === 1) {
          try { pUrl = unescape(pUrl); } catch (_) {}
        } else if (pUrl && enc === 2) {
          try { pUrl = unescape(b64ToUtf8(pUrl)); } catch (_) {}
        }
        if (/^https?:\/\//i.test(pUrl) && !/^https?:\/\/(?:[^/?#]+\.)?(?:youku|iqiyi|qq|mgtv|bilibili|sohu|le)\.com(?:\/|$)/i.test(pUrl)) {
          return { parse: 0, url: pUrl, header: { 'User-Agent': ua, Referer: playRes.host + '/' } };
        }
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // Group 8: wexqiwei-v1 (AiQwMkv)
  // =========================================================================
  if (cfg.adapter === 'wexqiwei-v1') {
    var qwHostList = null;
    var qwState = {
      current: '',
      getHosts: function () {
        if (!qwHostList) {
          qwHostList = expandHostCandidates(pickSiteHosts(str(cfg.siteKey || 'qiwei'), [cfg.defaultHost]));
          if (!qwState.current && qwHostList.length) qwState.current = qwHostList[0];
        }
        return qwHostList;
      }
    };
    function qwCards(html, host) {
      var base = (host || qwState.current) + '/';
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
          vod_pic: safePic(pdfh(r, 'img&&data-original') || pdfh(r, 'img&&src'), base),
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
    __drpy.homeVod = function () {
      var res = reqFromHosts(qwState, '/');
      return { list: qwCards(res.body, res.host) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var res = reqFromHosts(qwState, '/vt/' + str(tid) + '-' + page + '.html');
      var list = qwCards(res.body, res.host);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var res = reqFromHosts(qwState, '/index.php/ajax/suggest?mid=1&limit=30&wd=' + encodeURIComponent(kw));
      var doc = res ? parseJsonSafe(res.body) : null;
      var list = [];
      if (isObj(doc) && Array.isArray(doc.list)) {
        list = doc.list.map(function (it) {
          if (!isObj(it) || !it.id || !it.name) return null;
          return { vod_id: '/mv/' + it.id + '.html', vod_name: str(it.name), vod_pic: safePic(it.pic, res.host + '/'), vod_remarks: '' };
        }).filter(Boolean);
      }
      return { page: 1, pagecount: 1, limit: 30, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var res = reqFromHosts(qwState, str(vid));
      var html = res.body;
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
          vod_pic: safePic(pdfh(html, '.imgblock img&&src') || pdfh(html, 'img&&src'), res.host + '/'),
          vod_content: stripHtml(pdfh(html, '.zkjj_a&&Text') || pdfh(html, '.sqjj_a&&Text')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var s = str(id).trim();
      if (s.indexOf('qwplay:') === 0) {
        var res = reqFromHosts(qwState, s.slice(7));
        var html = res.body;
        var m = /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</i.exec(html);
        var pj = m ? parseJsonSafe(m[1]) : null;
        if (isObj(pj) && str(pj.url)) {
          var u = str(pj.url);
          if (Number(pj.encrypt) === 1) u = unescape(u);
          else if (Number(pj.encrypt) === 2) u = unescape(b64ToUtf8(u));
          if (/^https?:\/\//i.test(u)) return { parse: 0, url: address(u).url, header: { 'User-Agent': ua, Referer: res.host + '/' } };
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

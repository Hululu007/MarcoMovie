// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';

const VOD_ADAPTERS = Object.freeze([
  'jpys-v1', 'jpj-v1', 'nmyswv-v1', 'hmys-v1', 'app99-v1', 'appsx-v1', 'newcz-v1', 'libvio-v1', 'ygp-v1', 'jumitv-v1'
]);

function installFtyVod() {
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
  function hexToB64(hexVal) {
    return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Hex.parse(str(hexVal).trim()));
  }
  function aesCbcDecryptText(cipherB64, keyStr, ivStr) {
    var keyB64 = utf8ToB64(keyStr);
    var ivB64 = utf8ToB64(ivStr);
    var algo = keyStr.length > 16 ? 'aes-256-cbc' : 'aes-128-cbc';
    var out = nodeCipher('decrypt', algo, keyB64, ivB64, cipherB64, '');
    return b64ToUtf8(out.data);
  }
  function aesCbcEncryptB64(plainStr, keyStr, ivStr) {
    var keyB64 = utf8ToB64(keyStr);
    var ivB64 = utf8ToB64(ivStr);
    var algo = keyStr.length > 16 ? 'aes-256-cbc' : 'aes-128-cbc';
    var out = nodeCipher('encrypt', algo, keyB64, ivB64, utf8ToB64(plainStr), '');
    return out.data;
  }
  function randomHex(len) {
    var arr = new Uint8Array(Math.ceil(len / 2));
    crypto.getRandomValues(arr);
    var s = '';
    for (var i = 0; i < arr.length; i++) s += ('0' + arr[i].toString(16)).slice(-2);
    return s.slice(0, len);
  }
  function randomUuid() {
    var h = randomHex(32);
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-4' + h.slice(13, 16) + '-a' + h.slice(17, 20) + '-' + h.slice(20, 32);
  }
  function httpReq(url, opts) {
    var r;
    try { r = req(url, Object.assign({ timeout: 10000 }, opts || {})); }
    catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    if (!r || typeof r.content !== 'string') fail('drpy_source_unavailable');
    checkChallenge(r.content);
    return r;
  }
  function httpReqSoft(url, opts) {
    try {
      var r = req(url, Object.assign({ timeout: 4500 }, opts || {}));
      if (!r || typeof r.content !== 'string') return { ok: false, code: 0, content: '' };
      if (/(?:SafeLineChallenge|__cdn_pow|sl-challenge-jwt|Checking your browser|系统安全验证|正在验证您的浏览器|人机验证|verify you are human|验证码不正确|请完成滑块验证|verifySlider|challenges\.cloudflare\.com|<title>\s*Just a moment\.\.\.\s*<\/title>|cf-turnstile)/i.test(r.content) ||
          /<input[^>]+(?:name|id)=["']?(?:verify|validate|captcha)/i.test(r.content)) {
        return { ok: false, code: 403, challenge: true, content: r.content };
      }
      return { ok: r.code >= 200 && r.code < 400, code: r.code, content: r.content, headers: r.headers };
    } catch (_) {
      return { ok: false, code: 0, content: '' };
    }
  }
  function isDirectMedia(u) {
    return /\.(?:m3u8|mp4|flv|mpd|mkv|ts|mp3|m4a)(?:[?#]|$)/i.test(str(u));
  }
  function isPanShare(u) {
    return /(?:pan\.quark\.cn|drive\.uc\.cn|pan\.baidu\.com|aliyundrive\.com|alipan\.com|cloud\.189\.cn|115\.com|115cdn\.com|123pan\.com|123684\.com|123865\.com|123912\.com|caiyun\.139\.com)/i.test(str(u));
  }

  // ==================== 1. jpys-v1 (Jpys) ====================
  if (cfg.adapter === 'jpys-v1') {
    var jpHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    var deviceId = randomUuid();
    function jpGet(pathAndQuery, signInput) {
      var t = String(Date.now());
      var raw = (signInput ? (signInput + cfg.signSuffix + t) : (cfg.signSuffix.replace(/^&/, '') + t));
      var sign = CryptoJS.SHA1(CryptoJS.MD5(raw).toString()).toString();
      var r = httpReq(jpHost + pathAndQuery, {
        headers: { 'User-Agent': cfg.userAgent, deviceid: deviceId, t: t, sign: sign, Accept: 'application/json,*/*' }
      });
      if (r.code < 200 || r.code >= 300) fail();
      var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      return isObj(doc) ? (doc.data !== undefined ? doc.data : doc) : {};
    }
    function jpCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vodId || it.id).trim();
      var name = str(it.vodName || it.title).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vodPic || it.pic, jpHost + '/'),
        vod_remarks: str(it.vodVersion || it.vodRemarks || it.remarks).trim()
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '综艺' },
          { type_id: '4', type_name: '动漫' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var d = jpGet('/api/mw-movie/anonymous/home/hotSearch', '');
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      return { list: arr.map(jpCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = extend || {};
      var area = str(ext.area).trim();
      var year = str(ext.year).trim();
      var qs = 'area=' + encodeURIComponent(area) + '&pageNum=' + page + '&type1=' + encodeURIComponent(str(tid)) + '&year=' + encodeURIComponent(year);
      var signQs = 'area=' + area + '&pageNum=' + page + '&type1=' + str(tid) + '&year=' + year;
      var d = jpGet('/api/mw-movie/anonymous/video/list?' + qs, signQs);
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(jpCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 15, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 8, total: 0, list: [] };
      var path = '/api/mw-movie/anonymous/video/searchByWord?keyword=' + encodeURIComponent(kw) + '&pageNum=' + page + '&pageSize=12';
      var signIn = 'keyword=' + kw + '&pageNum=' + page + '&pageSize=12';
      var d = jpGet(path, signIn);
      var arr = isObj(d) && isObj(d.result) && Array.isArray(d.result.list) ? d.result.list :
                (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      var list = arr.map(jpCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 12, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var vid = str(id).trim();
      var d = jpGet('/api/mw-movie/anonymous/video/detail?id=' + encodeURIComponent(vid), 'id=' + vid);
      if (!isObj(d)) fail('drpy_source_response');
      var eps = Array.isArray(d.episodeList) ? d.episodeList : [];
      var urls = [];
      eps.forEach(function (ep, idx) {
        if (!isObj(ep)) return;
        var nid = str(ep.nid || ep.id).trim();
        if (!nid) return;
        var epName = str(ep.name || ('第' + (idx + 1) + '集')).replace(/[$#]/g, ' ').trim();
        urls.push(epName + '$' + vid + '@@@' + nid);
      });
      return {
        list: [{
          vod_id: vid,
          vod_name: str(d.vodName || vid).trim(),
          vod_pic: safePic(d.vodPic, jpHost + '/'),
          type_name: str(d.vodClass).trim(),
          vod_year: str(d.vodYear).trim(),
          vod_area: str(d.vodArea).trim(),
          vod_remarks: str(d.vodRemarks || d.vodVersion).trim(),
          vod_actor: str(d.vodActor).trim(),
          vod_director: str(d.vodDirector).trim(),
          vod_content: stripHtml(d.vodContent || d.vodBlurb),
          vod_play_from: urls.length ? '金牌线路' : '',
          vod_play_url: urls.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var parts = str(id).split('@@@');
      if (parts.length >= 2) {
        var vid = parts[0], nid = parts[1];
        var q = 'clientType=3&id=' + vid + '&nid=' + nid;
        var d = jpGet('/api/mw-movie/anonymous/v2/video/episode/url?' + q, q);
        var list = isObj(d) && Array.isArray(d.list) ? d.list : [];
        var chosen = list.length ? str(list[0].url).trim() : str(d.url || d.playUrl).trim();
        if (!chosen) fail('drpy_media_unresolved');
        return { parse: 0, url: address(chosen, jpHost + '/').url, header: { 'User-Agent': cfg.userAgent, Referer: jpHost + '/' } };
      }
      return { parse: 0, url: address(id, jpHost + '/').url, header: { 'User-Agent': cfg.userAgent } };
    };
    return;
  }

  // ==================== 2. jpj-v1 (JPJ / 荐片) ====================
  if (cfg.adapter === 'jpj-v1') {
    var jpjHost = str(cfg.defaultHost).replace(/\/+$/, '');
    var jpjImgDomain = '';
    var jpjResolved = false;
    function ensureJpjHost() {
      if (jpjResolved) return;
      jpjResolved = true;
      var candidates = [];
      if (str(cfg.extText) && /^https?:\/\//i.test(str(cfg.extText))) {
        str(cfg.extText).split(/[|,;\s]+/).forEach(function (u) { if (/^https?:\/\//i.test(u)) candidates.push(u.replace(/\/+$/, '')); });
      }
      try {
        var dnsRes = req(cfg.alidnsUrl, { timeout: 2200, headers: { Accept: 'application/json' } });
        if (dnsRes && dnsRes.code === 200 && typeof dnsRes.content === 'string') {
          var dnsDoc = JSON.parse(dnsRes.content);
          if (dnsDoc && Array.isArray(dnsDoc.Answer)) {
            dnsDoc.Answer.forEach(function (ans) {
              var txt = str(ans && ans.data).replace(/["\\\s]/g, '');
              txt.split(',').forEach(function (dom) {
                if (dom && /^[a-z0-9.-]+$/i.test(dom)) candidates.push(cfg.fanPrefix + dom);
              });
            });
          }
        }
      } catch (_) {}
      candidates.push(jpjHost);
      var probeLimit = Math.min(candidates.length, 3);
      for (var i = 0; i < probeLimit; i++) {
        var cand = candidates[i].replace(/\/+$/, '');
        try {
          var r = req(cand + cfg.domainConfigPath, { timeout: 2200, headers: { 'User-Agent': cfg.userAgent } });
          if (r && r.code >= 200 && r.code < 300 && typeof r.content === 'string') {
            jpjHost = cand;
            try {
              var cd = JSON.parse(r.content);
              if (cd && cd.data && cd.data.imgDomain) {
                var idom = str(cd.data.imgDomain).split(',')[0].trim();
                if (idom) jpjImgDomain = /^https?:\/\//i.test(idom) ? idom.replace(/\/+$/, '') : ('https://' + idom.replace(/\/+$/, ''));
              }
            } catch (_) {}
            break;
          }
        } catch (_) {}
      }
    }
    function jpjPic(p) {
      var s = str(p).trim();
      if (!s) return '';
      if (/^https?:\/\//i.test(s)) return safePic(s);
      if (jpjImgDomain) return safePic(jpjImgDomain + (s.charAt(0) === '/' ? s : '/' + s));
      return safePic(s, jpjHost + '/');
    }
    function jpjGet(path) {
      ensureJpjHost();
      var r = httpReq(jpjHost + path, { headers: { 'User-Agent': cfg.userAgent, Accept: 'application/json,*/*' } });
      if (r.code < 200 || r.code >= 300) fail();
      var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      return isObj(doc) ? doc.data : null;
    }
    function jpjCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.id || it.vod_id).trim();
      var name = str(it.title || it.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: jpjPic(it.path || it.thumbnail || it.cover_image || it.vod_pic),
        vod_remarks: str(it.mask || it.playlist && it.playlist.title || it.score || '').trim()
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '动漫' },
          { type_id: '4', type_name: '综艺' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var d = jpjGet('/api/slide/list?pos_id=88');
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      return { list: arr.map(jpjCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = extend || {};
      var area = str(ext.area || '0'), year = str(ext.year || '0'), sort = str(ext.by || 'hot');
      var path = '/api/crumb/list?fcate_pid=' + encodeURIComponent(str(tid)) + '&area=' + encodeURIComponent(area) + '&year=' + encodeURIComponent(year) + '&type=0&sort=' + encodeURIComponent(sort) + '&page=' + page + '&category_id=';
      var d = jpjGet(path);
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      var list = arr.map(jpjCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 15 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var d = jpjGet('/api/v2/search/videoV2?key=' + encodeURIComponent(kw) + '&category_id=88&page=' + page + '&pageSize=20');
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.data) ? d.data : (isObj(d) && Array.isArray(d.list) ? d.list : []));
      var list = arr.map(jpjCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var vid = str(id).trim();
      var d = jpjGet('/api/video/detailv2?id=' + encodeURIComponent(vid));
      if (!isObj(d)) fail('drpy_source_response');
      var froms = [], groups = [];
      var srcList = Array.isArray(d.source_list_source) ? d.source_list_source : [];
      srcList.forEach(function (line, idx) {
        if (!isObj(line)) return;
        var lineName = str(line.name || ('线路' + (idx + 1))).trim();
        if (/常规/.test(lineName)) lineName = lineName.replace(/常规/g, '边下边播');
        var items = Array.isArray(line.source_list) ? line.source_list : [];
        var eps = [];
        items.forEach(function (ep, eIdx) {
          if (!isObj(ep)) return;
          var u = str(ep.url).trim();
          if (!u || /^(?:magnet:|tvbox-xg:|jianpian:|ed2k:|thunder:)/i.test(u)) return;
          if (!/^https?:\/\//i.test(u)) return;
          var en = str(ep.source_name || ep.weight || ('第' + (eIdx + 1) + '集')).replace(/[$#]/g, ' ').trim();
          eps.push(en + '$' + u);
        });
        if (eps.length) {
          froms.push(lineName);
          groups.push(eps.join('#'));
        }
      });
      return {
        list: [{
          vod_id: vid,
          vod_name: str(d.title || vid).trim(),
          vod_pic: jpjPic(d.thumbnail || d.path),
          vod_year: str(d.year).trim(),
          vod_area: str(d.area).trim(),
          vod_remarks: str(d.mask || d.score).trim(),
          vod_content: stripHtml(d.description),
          vod_play_from: froms.join('$$$'),
          vod_play_url: groups.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      return { parse: 0, url: address(id, jpjHost + '/').url, header: { 'User-Agent': cfg.userAgent } };
    };
    return;
  }

  // ==================== 3. nmyswv-v1 (Nmyswv / 农民影视) ====================
  if (cfg.adapter === 'nmyswv-v1') {
    var nmHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    var nmUa = 'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
    function nmHtml(pathOrUrl) {
      var u = address(pathOrUrl, nmHost + '/').url;
      var r = httpReq(u, { headers: { 'User-Agent': nmUa, Referer: nmHost + '/' } });
      if (r.code < 200 || r.code >= 400) fail();
      return r.content;
    }
    function nmList(html) {
      var nodes = pdfa(html, 'div.globalPicList ul li');
      if (!nodes.length) nodes = pdfa(html, 'ul.resize_list li');
      if (!nodes.length) nodes = pdfa(html, 'ul#data_list li');
      return nodes.map(function (n) {
        var href = pdfh(n, 'a&&href');
        var name = pdfh(n, 'span.sTit&&Text') || pdfh(n, 'a&&title');
        if (!href || !name) return null;
        return {
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(n, 'img&&data-src') || pdfh(n, 'img&&src'), nmHost + '/'),
          vod_remarks: pdfh(n, 'a > div > span.sBottom > span&&Text') || pdfh(n, 'span.sDes&&Text')
        };
      }).filter(Boolean);
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '综艺' },
          { type_id: '4', type_name: '动漫' },
          { type_id: '26', type_name: '短剧' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      return { list: nmList(nmHtml(nmHost + '/')) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = extend || {};
      var by = str(ext.by || 'time'), year = str(ext.year), area = str(ext.area);
      var u = '/index.php?m=vod-list-id-' + encodeURIComponent(str(tid)) + '-pg-' + page + '-order--by-' + encodeURIComponent(by) + '-class--year-' + encodeURIComponent(year) + '-letter--area-' + encodeURIComponent(area) + '-lang-.html';
      var list = nmList(nmHtml(u));
      return { page: page, pagecount: list.length ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var r = httpReq(nmHost + '/index.php?m=vod-search', {
        method: 'POST',
        headers: { 'User-Agent': nmUa, 'Content-Type': 'application/x-www-form-urlencoded', Referer: nmHost + '/' },
        body: 'wd=' + encodeURIComponent(kw)
      });
      var list = nmList(r.content);
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var html = nmHtml(id);
      var tabs = pdfa(html, 'div.numTab a');
      var boxes = pdfa(html, 'div.numList ul');
      if (!boxes.length) boxes = pdfa(html, 'ul.list_tab_img');
      var froms = [], groups = [];
      boxes.forEach(function (box, idx) {
        var tabName = tabs[idx] ? pdfh(tabs[idx], 'a&&Text') : ('线路' + (idx + 1));
        var eps = pdfa(box, 'a').map(function (a) {
          var h = pdfh(a, 'a&&href'), t = pdfh(a, 'a&&Text');
          return (h && t) ? (t.replace(/[$#]/g, ' ').trim() + '$' + h) : '';
        }).filter(Boolean);
        if (eps.length) {
          froms.push(tabName || ('线路' + (idx + 1)));
          groups.push(eps.join('#'));
        }
      });
      return {
        list: [{
          vod_id: str(id),
          vod_name: pdfh(html, 'h1&&Text') || pdfh(html, 'div.pagehd h1&&Text') || str(id),
          vod_pic: safePic(pdfh(html, 'div.posterPic img&&src') || pdfh(html, 'img.lazy&&src'), nmHost + '/'),
          vod_content: stripHtml(pdfh(html, 'div.introTxt&&Html') || pdfh(html, 'p.txtDesc&&Html')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: groups.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (isDirectMedia(id)) return { parse: 0, url: address(id, nmHost + '/').url, header: { 'User-Agent': nmUa, Referer: nmHost + '/' } };
      var html = nmHtml(id);
      var srcIdx = (/vod-play-id-\d+-src-(\d+)-num-\d+/.exec(str(id)) || [0, '1'])[1];
      var numIdx = (/vod-play-id-\d+-src-\d+-num-(\d+)/.exec(str(id)) || [0, '1'])[1];
      var macMatch = /mac_url\s*=\s*['"]([^'"]+)['"]/.exec(html);
      if (macMatch && macMatch[1]) {
        var lines = macMatch[1].split('$$$');
        var line = lines[Math.max(0, Number(srcIdx) - 1)] || lines[0] || '';
        var eps = line.split('#');
        var ep = eps[Math.max(0, Number(numIdx) - 1)] || eps[0] || '';
        var target = ep.indexOf('$') >= 0 ? ep.split('$')[1] : ep;
        if (target && isDirectMedia(target)) {
          return { parse: 0, url: address(target, nmHost + '/').url, header: { 'User-Agent': nmUa, Referer: nmHost + '/' } };
        }
        if (target) {
          var iframeSrc = pdfh(html, 'iframe&&src');
          if (iframeSrc) {
            var pHtml = nmHtml(iframeSrc);
            var m3u8 = (/["'](https?:\/\/[^"']+\.(?:m3u8|mp4)[^"']*)["']/i.exec(pHtml) || [])[1];
            if (m3u8) return { parse: 0, url: address(m3u8).url, header: { 'User-Agent': nmUa, Referer: nmHost + '/' } };
          }
        }
      }
      var directMatch = /["'](https?:\/\/[^"']+\.(?:m3u8|mp4)[^"']*)["']/i.exec(html);
      if (directMatch && directMatch[1]) {
        return { parse: 0, url: address(directMatch[1]).url, header: { 'User-Agent': nmUa, Referer: nmHost + '/' } };
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 4. hmys-v1 (Hmys / 海绵影视) ====================
  if (cfg.adapter === 'hmys-v1') {
    var hmExt = isObj(cfg.ext) ? cfg.ext : {};
    var initUrl = str(hmExt.tokenUrl || hmExt.url || hmExt.host || cfg.defaultInitUrl).trim();
    var isV2 = /init_v2|new_public/i.test(initUrl);
    var hmAppName = str(hmExt.appName || (isV2 ? 'xingkongshipin' : cfg.appName));
    var hmChannel = str(hmExt.channelCode || (isV2 ? cfg.v2Channel : cfg.channelCode));
    var hmPkg = str(hmExt.packageName || (isV2 ? cfg.v2Pkg : cfg.packageName));
    var hmSignKey = str(hmExt.sginKey || hmExt.signKey || (isV2 ? cfg.v2SignKey : cfg.signKey));
    var hmVersion = isV2 ? '50100' : '43000';
    var hmAesKey = str(hmExt.key || cfg.aesKey);
    var hmAesIv = str(hmExt.iv || (isV2 ? cfg.aesIv2 : cfg.aesIv1));
    var hmDeviceId = CryptoJS.MD5(randomHex(24)).toString().slice(0, 16);
    var hmToken = '';
    var hmApiBase = '';
    var hmInited = false;

    function hmDecrypt(rawText) {
      var clean = str(rawText).trim().replace(/^"+|"+$/g, '');
      if (!clean) fail('drpy_source_response');
      if (clean.charAt(0) === '{' || clean.charAt(0) === '[') return JSON.parse(clean);
      varivs = [hmAesIv, cfg.aesIv1, cfg.aesIv2];
      for (var i = 0; i < varivs.length; i++) {
        try {
          var dec = aesCbcDecryptText(clean, hmAesKey, varivs[i]);
          if (dec && (dec.trim().charAt(0) === '{' || dec.trim().charAt(0) === '[')) return JSON.parse(dec.trim());
        } catch (_) { globalThis.__drpyUnsupported = null; }
      }
      fail('drpy_source_response');
    }
    var varivs;

    function hmHeaders(paramsObj) {
      var curTime = String(Math.floor(Date.now() / 1000));
      var hdr = {
        'User-Agent': isV2 ? cfg.uaOk412 : cfg.uaOk49,
        'log-header': 'I am the log request header.',
        app_name: hmAppName,
        channel_code: hmChannel,
        cur_time: curTime,
        device_id: hmDeviceId,
        mob_mfr: 'Xiaomi',
        mobmodel: '22041211AC',
        package_name: hmPkg,
        sys_platform: 'android',
        sysrelease: '12',
        version: hmVersion
      };
      if (hmToken) hdr.token = hmToken;
      var signPairs = Object.assign({}, paramsObj || {}, {
        app_name: hmAppName,
        channel_code: hmChannel,
        cur_time: curTime,
        device_id: hmDeviceId,
        package_name: hmPkg,
        sys_platform: 'android',
        version: hmVersion
      });
      if (hmToken) signPairs.token = hmToken;
      var keys = Object.keys(signPairs).sort();
      var parts = [];
      keys.forEach(function (k) {
        var v = str(signPairs[k]);
        if (v !== '') parts.push(k + '=' + v);
      });
      var signRaw = parts.join('&') + '&key=' + hmSignKey;
      hdr.sign = CryptoJS.MD5(signRaw).toString();
      return hdr;
    }

    function hmCall(urlOrPath, params) {
      var u = /^https?:\/\//i.test(urlOrPath) ? urlOrPath : (hmApiBase + urlOrPath);
      var qs = [];
      var p = params || {};
      Object.keys(p).forEach(function (k) {
        if (p[k] !== undefined && p[k] !== null && str(p[k]) !== '') {
          qs.push(encodeURIComponent(k) + '=' + encodeURIComponent(str(p[k])));
        }
      });
      var fullUrl = qs.length ? (u + (u.indexOf('?') >= 0 ? '&' : '?') + qs.join('&')) : u;
      var r = httpReq(fullUrl, { headers: hmHeaders(p) });
      if (r.code < 200 || r.code >= 300) fail();
      var doc = hmDecrypt(r.content);
      return isObj(doc) && isObj(doc.data) ? doc.data : doc;
    }

    function ensureHmInit() {
      if (hmInited) return;
      hmInited = true;
      if (str(hmExt.api) && /^https?:\/\//i.test(str(hmExt.api))) {
        hmApiBase = str(hmExt.api).replace(/\/+$/, '');
      }
      try {
        var d = hmCall(initUrl, {});
        if (isObj(d)) {
          if (d.token) hmToken = str(d.token);
          else if (isObj(d.user_info) && d.user_info.token) hmToken = str(d.user_info.token);
          var apiCand = str(d.api_url || (Array.isArray(d.api_url_list) ? d.api_url_list[0] : '')).trim();
          if (apiCand && /^https?:\/\//i.test(apiCand)) hmApiBase = apiCand.replace(/\/+$/, '');
        }
      } catch (_) { globalThis.__drpyUnsupported = null; }
      if (!hmApiBase) hmApiBase = address(initUrl).origin;
    }

    function hmCdnSign(mediaUrl, ckStr, sKey) {
      var clean = str(mediaUrl).split('?')[0];
      var m = /^https?:\/\/[^/?#]+(\/[^?#]*)/.exec(clean);
      var pathname = m ? m[1] : '/';
      var key = str(sKey).trim() || hmSignKey;
      var hexTime = Math.floor(Date.now() / 1000).toString(16);
      var wsSecret = CryptoJS.MD5(key + pathname + hexTime).toString();
      var ck = str(ckStr).trim();
      if (ck && ck.indexOf('Time=') < 0 && ck.indexOf('k=') !== 0 && ck.indexOf('az=') !== 0) {
        try { ck = b64ToUtf8(ck).trim(); } catch (_) {}
      }
      return clean + '?' + (ck ? (ck + '&') : '') + 'wsSecret=' + wsSecret + '&wsTime=' + hexTime;
    }

    function hmCard(it) {
      if (!isObj(it)) return null;
      var info = isObj(it.vod_info) ? it.vod_info : it;
      var id = str(info.id || info.vod_id).trim();
      var name = str(info.vod_name || info.title).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(info.vod_pic || info.pic),
        vod_remarks: str(info.vod_remarks || info.collection_new_title || info.vod_serial || info.vod_total).trim()
      };
    }

    __drpy.home = function () {
      ensureHmInit();
      var path = str(hmExt.typePath || (isV2 ? '/api/new_type/list_v2' : '/api/type/get_list'));
      var d = hmCall(path, {});
      var list = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      var classes = [];
      list.forEach(function (c) {
        if (!isObj(c)) return;
        var tid = str(c.id || c.type_id).trim();
        var tname = str(c.type_name || c.name).replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, '').trim();
        if (tid && tname && !/推荐|精选/.test(tname)) classes.push({ type_id: tid, type_name: tname });
      });
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      ensureHmInit();
      var path = str(hmExt.channelPath || (isV2 ? '/api/new_channel/get_info_v2' : '/api/channel/get_info'));
      var d = hmCall(path, { id: '1' });
      var out = [], seen = Object.create(null);
      var blocks = isObj(d) && Array.isArray(d.vod_list) ? d.vod_list : (Array.isArray(d) ? d : []);
      blocks.forEach(function (b) {
        var sub = isObj(b) && Array.isArray(b.list) ? b.list : [b];
        sub.forEach(function (it) {
          var c = hmCard(it);
          if (c && !seen[c.vod_id]) { seen[c.vod_id] = true; out.push(c); }
        });
      });
      return { list: out };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      ensureHmInit();
      var page = Math.max(1, Number(pg) || 1);
      var path = str(hmExt.categoryPath || (isV2 ? '/api/new_search/result_v2' : '/api/search/result'));
      var d = hmCall(path, { type_id: str(tid), page: String(page), page_size: '18' });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(hmCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 18 ? page + 1 : page, limit: 18, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      ensureHmInit();
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 18, total: 0, list: [] };
      var path = str(hmExt.searchPath || (isV2 ? '/api/new_search/result_v2' : '/api/search/result'));
      var d = hmCall(path, { keyword: kw, word: kw, page: String(page), page_size: '18' });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(hmCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 18 ? page + 1 : page, limit: 18, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      ensureHmInit();
      var vid = str(id).trim();
      var path = str(hmExt.collectionPath || (isV2 ? '/api/new_video/collection_v2' : '/api/video/collection'));
      var d = hmCall(path, { id: vid, vod_id: vid });
      var info = isObj(d) && isObj(d.vod_info) ? d.vod_info : (isObj(d) ? d : {});
      var ck = str(d.nc_token || d.vod_token || info.nc_token || info.vod_token).trim();
      var cols = Array.isArray(d.vod_collection) ? d.vod_collection : (Array.isArray(info.vod_collection) ? info.vod_collection : []);
      var eps = [];
      cols.forEach(function (ep, idx) {
        if (!isObj(ep)) return;
        var cid = str(ep.id || ep.collection_id).trim();
        var epUrl = str(ep.vod_url || ep.url).trim();
        var epName = str(ep.collection_title || ep.title || ('第' + (idx + 1) + '集')).replace(/[$#]/g, ' ').trim();
        var payload = JSON.stringify({ vod_id: vid, collection_id: cid, vod_url: epUrl, ck: ck });
        eps.push(epName + '$' + utf8ToB64(payload));
      });
      return {
        list: [{
          vod_id: vid,
          vod_name: str(info.vod_name || info.title || vid).trim(),
          vod_pic: safePic(info.vod_pic || info.pic),
          type_name: str(info.vod_tag || info.type_name).trim(),
          vod_year: str(info.vod_year).trim(),
          vod_area: str(info.vod_area).trim(),
          vod_remarks: str(info.vod_remarks).trim(),
          vod_actor: str(info.vod_actor).trim(),
          vod_director: str(info.vod_director).trim(),
          vod_content: stripHtml(info.vod_content),
          vod_play_from: eps.length ? '海绵专线' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      ensureHmInit();
      var meta = {};
      try { meta = JSON.parse(b64ToUtf8(id)); } catch (_) {}
      var vodUrl = str(meta.vod_url).trim();
      var ck = str(meta.ck).trim();
      if (!vodUrl && meta.collection_id) {
        var rPath = isV2 ? '/api/new_video/result_v2' : '/api/video/result';
        var rd = hmCall(rPath, { vod_id: str(meta.vod_id), collection_id: str(meta.collection_id) });
        if (isObj(rd)) {
          vodUrl = str(rd.vod_url || rd.url).trim();
          ck = str(rd.nc_token || rd.vod_token || ck).trim();
        }
      }
      if (!vodUrl) fail('drpy_media_unresolved');
      if (ck && /\.m3u8(?:[?#]|$)/i.test(vodUrl)) {
        var proxyUrl = getProxy() + '&type=m3u8&url=' + encodeURIComponent(utf8ToB64(vodUrl)) + '&ck=' + encodeURIComponent(ck) + '&sign=' + encodeURIComponent(hmSignKey);
        return { parse: 0, url: proxyUrl, header: { 'User-Agent': 'Mozi', Accept: '*/*' } };
      }
      return { parse: 0, url: address(vodUrl).url, header: { 'User-Agent': 'Mozi', Accept: '*/*' } };
    };
    __drpy.proxy = function (params) {
      var p = params || {};
      var rawUrl = b64ToUtf8(str(p.url));
      var ck = str(p.ck);
      var sKey = str(p.sign) || hmSignKey;
      var signedM3u8 = hmCdnSign(rawUrl, ck, sKey);
      var r = httpReq(signedM3u8, { headers: { 'User-Agent': 'Mozi', Accept: '*/*' } });
      if (r.code < 200 || r.code >= 300 || r.content.indexOf('#EXTM3U') < 0) fail('drpy_media_unresolved');
      var baseClean = rawUrl.split('?')[0];
      var lines = r.content.split(/\r?\n/).map(function (line) {
        var trimmed = line.trim();
        if (!trimmed || trimmed.charAt(0) === '#') return line;
        var abs = joinUrl(baseClean, trimmed.split('?')[0]);
        return hmCdnSign(abs, ck, sKey);
      });
      return [200, 'application/vnd.apple.mpegurl', lines.join('\n')];
    };
    return;
  }

  // ==================== 5. app99-v1 (App99) ====================
  if (cfg.adapter === 'app99-v1') {
    var a9Ext = isObj(cfg.ext) ? cfg.ext : {};
    var a9Host = str(a9Ext.host || a9Ext.url || cfg.origin).replace(/\/+$/, '');
    var a9AppKey = str(a9Ext.appkey || a9Ext.appKey).trim();
    var a9AesKey = str(a9Ext.key || a9Ext.aesKey).trim();
    var a9AesIv = str(a9Ext.iv || cfg.defaultIv).trim();
    var a9Ver = str(a9Ext.apiVersion || a9Ext.version || '1.0.0').trim();
    var a9Token = '';
    var a9Parses = Object.create(null);
    var a9Cats = [];
    var a9Inited = false;

    function a9Req(path, bodyObj) {
      var ts = String(Math.floor(Date.now() / 1000));
      var nonce = randomHex(16);
      var bodyStr = JSON.stringify(bodyObj || {});
      var encBody = a9AesKey ? aesCbcEncryptB64(bodyStr, a9AesKey, a9AesIv) : bodyStr;
      var signStr = [a9AppKey, ts, nonce, a9Ver, bodyStr].join(':');
      var sign = CryptoJS.MD5(signStr).toString();
      var hdr = {
        'User-Agent': cfg.userAgent,
        'Content-Type': 'application/json',
        appkey: a9AppKey,
        timestamp: ts,
        nonce: nonce,
        api_version: a9Ver,
        sign: sign
      };
      if (a9Token) { hdr.token = a9Token; hdr.usertoken = a9Token; }
      var r = httpReq(a9Host + path, { method: 'POST', headers: hdr, body: a9AesKey ? JSON.stringify({ data: encBody }) : bodyStr });
      if (r.code < 200 || r.code >= 300) fail();
      var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      var payload = isObj(doc) ? (doc.data !== undefined ? doc.data : doc) : doc;
      if (typeof payload === 'string' && a9AesKey && payload.trim().charAt(0) !== '{') {
        try { payload = JSON.parse(aesCbcDecryptText(payload.trim(), a9AesKey, a9AesIv)); } catch (_) {}
      }
      return payload;
    }

    function ensureA9Init() {
      if (a9Inited) return;
      a9Inited = true;
      try {
        var d = a9Req('/app/systemInit', {});
        if (isObj(d)) {
          if (d.token) a9Token = str(d.token);
          if (Array.isArray(d.categories)) a9Cats = d.categories;
          if (Array.isArray(d.parses)) {
            d.parses.forEach(function (p) {
              if (isObj(p) && p.name && (p.parseUrl || p.apiUrl || p.apiurl)) {
                a9Parses[str(p.name)] = str(p.parseUrl || p.apiUrl || p.apiurl);
              }
            });
          }
        }
      } catch (_) { globalThis.__drpyUnsupported = null; }
    }

    function a9Card(it) {
      if (!isObj(it)) return null;
      var id = str(it.vod_id || it.id).trim();
      var name = str(it.vod_name || it.name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vod_pic, a9Host + '/'),
        vod_remarks: str(it.vod_remarks).trim()
      };
    }

    __drpy.home = function () {
      ensureA9Init();
      var classes = a9Cats.map(function (c) {
        return isObj(c) && (c.type_id || c.id) && (c.type_name || c.name)
          ? { type_id: str(c.type_id || c.id), type_name: str(c.type_name || c.name) } : null;
      }).filter(Boolean);
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      ensureA9Init();
      var d = a9Req('/vod/search', { page: 1, limit: 21 });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      return { list: arr.map(a9Card).filter(Boolean) };
    };
    __drpy.category = function (tid, pg) {
      ensureA9Init();
      var page = Math.max(1, Number(pg) || 1);
      var d = a9Req('/vod/search', { type_id: str(tid), page: page, limit: 21 });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(a9Card).filter(Boolean);
      return { page: page, pagecount: list.length >= 21 ? page + 1 : page, limit: 21, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      ensureA9Init();
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 21, total: 0, list: [] };
      var d = a9Req('/vod/search', { keyword: kw, wd: kw, page: page, limit: 21 });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(a9Card).filter(Boolean);
      return { page: page, pagecount: list.length >= 21 ? page + 1 : page, limit: 21, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      ensureA9Init();
      var vid = str(id).trim();
      var d = a9Req('/vod/detail', { vod_id: vid, id: vid });
      var info = isObj(d) && isObj(d.vod) ? d.vod : (isObj(d) ? d : {});
      return {
        list: [{
          vod_id: str(info.vod_id || vid),
          vod_name: str(info.vod_name || vid),
          vod_pic: safePic(info.vod_pic, a9Host + '/'),
          vod_year: str(info.vod_year),
          vod_area: str(info.vod_area),
          vod_remarks: str(info.vod_remarks),
          vod_actor: str(info.vod_actor),
          vod_director: str(info.vod_director),
          vod_content: stripHtml(info.vod_content),
          vod_play_from: str(info.vod_play_from),
          vod_play_url: str(info.vod_play_url)
        }]
      };
    };
    __drpy.play = function (flag, id) {
      ensureA9Init();
      var raw = str(id).split('@')[0].trim();
      if (isDirectMedia(raw)) return { parse: 0, url: address(raw, a9Host + '/').url, header: { 'User-Agent': cfg.userAgent } };
      var pApi = a9Parses[str(flag)] || '';
      if (pApi && /^https?:\/\//i.test(pApi)) {
        var r = httpReq(pApi + encodeURIComponent(raw), { headers: { 'User-Agent': cfg.userAgent } });
        var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_media_unresolved'); }
        var u = str((isObj(doc.data) ? doc.data.url : '') || doc.url).trim();
        if (u) return { parse: 0, url: address(u).url, header: { 'User-Agent': cfg.userAgent } };
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 6. appsx-v1 (AppSx / getappapi & qijiappapi) ====================
  if (cfg.adapter === 'appsx-v1') {
    var sxExt = isObj(cfg.ext) ? cfg.ext : {};
    var sxHost = str(sxExt.host || sxExt.url || '').replace(/\/+$/, '');
    var sxDomainSpec = str(sxExt.domain).trim();
    var sxVer = Number(sxExt.ver) || 119;
    var sxVersionStr = str(sxExt.version || cfg.defaultVerStr);
    var sxAesKey = str(sxExt.key).trim();
    var sxAesIv = str(sxExt.iv || sxAesKey).trim();
    var sxUseRsaSession = str(sxExt.session) === '1';
    var sxUa = str(sxExt.ua || (sxVer > 119 ? cfg.uaOk314 : cfg.uaOk310));
    var sxDeviceId = str(sxExt.device || randomHex(32));
    var sxToken = str(sxExt.token || '');
    var sxPath = str(sxExt.path || (sxVer === 118 ? cfg.vodPath : sxVer > 119 ? cfg.qijiPath : cfg.defaultPath));
    var sxIndex = sxExt.index !== undefined ? str(sxExt.index) : (sxVer < 119 ? '' : 'index/');
    var sxInitMethod = str(sxExt.init || (sxVer > 122 ? 'initV4' : sxVer === 122 ? 'initV122' : sxVer === 120 ? 'initV120' : 'initV119'));
    var sxDetailMethod = str(sxExt.detail || (sxVer > 120 ? 'vodDetail3' : sxVer === 120 ? 'vodDetail2' : 'vodDetail'));
    var sxFilterMethod = str(sxExt.filter || 'typeFilterVodList');
    var sxSearchMethod = str(sxExt.search || 'searchList');
    var sxParseMethod = str(sxExt.vodParse || 'vodParse');
    var sxSessionId = '';
    var sxPlayerMap = Object.create(null);
    var sxTypeList = [];
    var sxBannerList = [];
    var sxInited = false;

    function sxDecrypt(textData) {
      var clean = str(textData).trim();
      if (!clean) return {};
      if (clean.charAt(0) === '{' || clean.charAt(0) === '[') return JSON.parse(clean);
      if (!sxAesKey) fail('drpy_source_response');
      var plain = aesCbcDecryptText(clean, sxAesKey, sxAesIv);
      return JSON.parse(plain);
    }

    function sxHeaders() {
      var ts = String(Math.floor(Date.now() / 1000));
      var sign = sxAesKey ? aesCbcEncryptB64(ts, sxAesKey, sxAesIv) : CryptoJS.MD5(ts).toString();
      var h = {
        'User-Agent': sxUa,
        'Content-Type': 'application/x-www-form-urlencoded',
        'app-version-code': sxVersionStr,
        'App-Version-Code': sxVersionStr,
        'app-platform': 'android',
        'app-user-device-id': sxDeviceId,
        'App-Device-Id': sxDeviceId,
        'app-api-verify-time': ts,
        'app-api-verify-sign': sign
      };
      if (sxToken) h['app-user-token'] = sxToken;
      if (sxSessionId) h['app-session-id'] = sxSessionId;
      if (typeof sxExt.header === 'string' && sxExt.header.trim().charAt(0) === '{') {
        try { Object.assign(h, JSON.parse(sxExt.header)); } catch (_) {}
      } else if (isObj(sxExt.header)) {
        Object.assign(h, sxExt.header);
      }
      return h;
    }

    function sxPost(methodName, formParams) {
      var pairs = [];
      var fp = formParams || {};
      Object.keys(fp).forEach(function (k) {
        if (fp[k] !== undefined && fp[k] !== null) {
          pairs.push(encodeURIComponent(k) + '=' + encodeURIComponent(str(fp[k])));
        }
      });
      var u = sxHost + sxPath + sxIndex + methodName;
      var r = httpReq(u, { method: 'POST', headers: sxHeaders(), body: pairs.join('&') });
      if (r.code < 200 || r.code >= 300) fail();
      var outer; try { outer = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      if (isObj(outer) && str(outer.msg)) checkChallenge(outer.msg);
      if (!isObj(outer)) fail('drpy_source_response');
      return outer.data !== undefined ? sxDecrypt(outer.data) : outer;
    }

    function ensureSxInit() {
      if (sxInited) return;
      sxInited = true;
      if (!sxHost && sxDomainSpec) {
        var domUrls = sxDomainSpec.split('|');
        for (var i = 0; i < domUrls.length; i++) {
          var du = domUrls[i].trim();
          if (!/^https?:\/\//i.test(du)) continue;
          try {
            var dr = req(du, { timeout: 4000, headers: { 'User-Agent': sxUa } });
            if (dr && dr.code >= 200 && dr.code < 300 && typeof dr.content === 'string') {
              var body = dr.content.trim();
              var resolved = '';
              if (body.charAt(0) === '[') { var arr = JSON.parse(body); resolved = arr[0] && (arr[0].domain || arr[0]); }
              else if (body.charAt(0) === '{') { var obj = JSON.parse(body); resolved = obj.domain || (Array.isArray(obj.data) ? obj.data[0] : ''); }
              else resolved = body.split(/[\r\n,]+/)[0].trim();
              resolved = str(resolved).trim();
              if (resolved) {
                sxHost = (/^https?:\/\//i.test(resolved) ? resolved : ('http://' + resolved)).replace(/\/+$/, '');
                break;
              }
            }
          } catch (_) {}
        }
      }
      if (!sxHost) sxHost = cfg.origin;
      if (sxUseRsaSession) {
        try {
          var pkData = sxPost('getPublicKey', {});
          var pubPem = str(pkData && pkData.public_key).trim();
          if (pubPem) {
            if (pubPem.indexOf('BEGIN') < 0) pubPem = '-----BEGIN PUBLIC KEY-----\n' + pubPem + '\n-----END PUBLIC KEY-----';
            var newKey = randomHex(16);
            var encKey = rsaPublicEncrypt(pubPem, utf8ToB64(newKey));
            var hs = sxPost('handshake', { encrypted_key: encKey });
            if (isObj(hs) && hs.session_id) {
              sxSessionId = str(hs.session_id);
              sxAesKey = newKey;
              sxAesIv = newKey;
            }
          }
        } catch (_) { globalThis.__drpyUnsupported = null; }
      }
      var initData = sxPost(sxInitMethod, {});
      if (isObj(initData)) {
        sxTypeList = Array.isArray(initData.type_list) ? initData.type_list : [];
        sxBannerList = Array.isArray(initData.banner_list) ? initData.banner_list : (Array.isArray(initData.recommend_list) ? initData.recommend_list : []);
        var pList = Array.isArray(initData.player_list) ? initData.player_list : [];
        pList.forEach(function (p) {
          if (isObj(p) && (p.from || p.code)) sxPlayerMap[str(p.from || p.code)] = p;
        });
      }
    }

    function sxCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vod_id).trim();
      var name = str(it.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vod_pic, sxHost + '/'),
        vod_remarks: str(it.vod_remarks).trim()
      };
    }

    __drpy.home = function () {
      ensureSxInit();
      var classes = sxTypeList.map(function (t) {
        return isObj(t) && t.type_id && t.type_name ? { type_id: str(t.type_id), type_name: str(t.type_name) } : null;
      }).filter(Boolean);
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      ensureSxInit();
      var list = sxBannerList.map(sxCard).filter(Boolean);
      sxTypeList.forEach(function (t) {
        if (isObj(t) && Array.isArray(t.recommend_list)) {
          t.recommend_list.forEach(function (v) { var c = sxCard(v); if (c) list.push(c); });
        }
      });
      return { list: list };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      ensureSxInit();
      var page = Math.max(1, Number(pg) || 1);
      var ext = extend || {};
      var d = sxPost(sxFilterMethod, {
        type_id: str(tid),
        page: String(page),
        class: str(ext.class || ''),
        area: str(ext.area || ''),
        lang: str(ext.lang || ''),
        year: str(ext.year || ''),
        sort: str(ext.by || '')
      });
      var arr = isObj(d) && Array.isArray(d.recommend_list) ? d.recommend_list : (Array.isArray(d) ? d : []);
      var list = arr.map(sxCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      ensureSxInit();
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var d = sxPost(sxSearchMethod, { keywords: kw, type_id: '0', page: String(page) });
      var arr = isObj(d) && Array.isArray(d.search_list) ? d.search_list : (Array.isArray(d) ? d : []);
      var list = arr.map(sxCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 15 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      ensureSxInit();
      var vid = str(id).trim();
      var d = sxPost(sxDetailMethod, { vod_id: vid });
      var vod = isObj(d) && isObj(d.vod) ? d.vod : (isObj(d) ? d : {});
      var playList = Array.isArray(d.vod_play_list) ? d.vod_play_list : (Array.isArray(vod.vod_play_list) ? vod.vod_play_list : []);
      var froms = [], groups = [];
      playList.forEach(function (line, idx) {
        if (!isObj(line)) return;
        var pInfo = isObj(line.player_info) ? line.player_info : (sxPlayerMap[str(line.from)] || {});
        var lineName = str(pInfo.show || line.show || line.from || ('线路' + (idx + 1))).trim();
        var parseApi = str(line.parse_api || pInfo.parse || pInfo.parse_api).trim();
        var parseType = str(line.player_parse_type || pInfo.player_parse_type || pInfo.parse_type || '0').trim();
        var uaVal = str(pInfo.user_agent || sxUa);
        var urls = Array.isArray(line.urls) ? line.urls : [];
        var eps = [];
        urls.forEach(function (ep, eIdx) {
          if (!isObj(ep)) return;
          var rawU = str(ep.url).trim();
          if (!rawU) return;
          var epToken = str(ep.token).trim();
          var epName = str(ep.name || ('第' + (eIdx + 1) + '集')).replace(/[$#]/g, ' ').trim();
          var payload = JSON.stringify({
            url: rawU,
            parse_api: parseApi,
            player_parse_type: parseType,
            token: epToken,
            ua: uaVal,
            vod_id: vid,
            player_source_id: str(line.player_source_id || ''),
            episode_index: str(ep.episode_index !== undefined ? ep.episode_index : eIdx)
          });
          eps.push(epName + '$' + utf8ToB64(payload));
        });
        if (eps.length) {
          froms.push(lineName);
          groups.push(eps.join('#'));
        }
      });
      return {
        list: [{
          vod_id: vid,
          vod_name: str(vod.vod_name || vid).trim(),
          vod_pic: safePic(vod.vod_pic, sxHost + '/'),
          type_name: str(vod.vod_class).trim(),
          vod_year: str(vod.vod_year).trim(),
          vod_area: str(vod.vod_area).trim(),
          vod_remarks: str(vod.vod_remarks).trim(),
          vod_actor: str(vod.vod_actor).trim(),
          vod_director: str(vod.vod_director).trim(),
          vod_content: stripHtml(vod.vod_content || vod.vod_blurb),
          vod_play_from: froms.join('$$$'),
          vod_play_url: groups.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      ensureSxInit();
      var meta = {};
      try { meta = JSON.parse(b64ToUtf8(id)); } catch (_) { meta = { url: str(id) }; }
      var rawU = str(meta.url).trim();
      var pApi = str(meta.parse_api).trim();
      var pType = str(meta.player_parse_type || '0');
      var playHdr = { 'User-Agent': str(meta.ua || sxUa) };
      if (isDirectMedia(rawU) && pType !== '2') {
        return { parse: 0, url: address(rawU, sxHost + '/').url, header: playHdr };
      }
      if (pType === '2' || !/^https?:\/\//i.test(rawU)) {
        try {
          var pd = sxPost(sxParseMethod, {
            parse_api: pApi,
            url: sxAesKey ? aesCbcEncryptB64(rawU, sxAesKey, sxAesIv) : rawU,
            token: str(meta.token),
            player_parse_type: pType,
            vod_id: str(meta.vod_id),
            player_source_id: str(meta.player_source_id),
            episode_index: str(meta.episode_index)
          });
          var inner = isObj(pd) && pd.json ? (typeof pd.json === 'string' ? JSON.parse(pd.json) : pd.json) : pd;
          var resolved = str(isObj(inner) ? (inner.url || inner.play_url) : '').trim();
          if (resolved) return { parse: 0, url: address(resolved).url, header: playHdr };
        } catch (e) {
          if (e && /^drpy_verification/.test(e.message)) throw e;
          globalThis.__drpyUnsupported = null;
        }
      }
      if (pApi && /^https?:\/\//i.test(pApi)) {
        var r = httpReq(pApi + encodeURIComponent(rawU), { headers: playHdr });
        var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_media_unresolved'); }
        var cu = str((isObj(doc.data) ? doc.data.url : '') || doc.url).trim();
        if (cu) return { parse: 0, url: address(cu).url, header: playHdr };
      }
      if (/^https?:\/\//i.test(rawU)) return { parse: 0, url: address(rawU).url, header: playHdr };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 7. newcz-v1 (NewCz / 厂长资源) ====================
  if (cfg.adapter === 'newcz-v1') {
    var czHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    function expandCzHosts() {
      var raw = [czHost];
      if (cfg.altHost) raw.push(str(cfg.altHost).replace(/\/+$/, ''));
      var out = [];
      var seen = Object.create(null);
      function addH(h) {
        var clean = str(h).trim().replace(/\/+$/, '');
        if (clean && !seen[clean]) { seen[clean] = 1; out.push(clean); }
      }
      for (var i = 0; i < raw.length; i++) {
        addH(raw[i]);
        try {
          var u = new URL(raw[i]);
          if (u.hostname.indexOf('www.') === 0) addH(u.protocol + '//' + u.hostname.slice(4) + (u.port ? ':' + u.port : ''));
          else addH(u.protocol + '//www.' + u.hostname + (u.port ? ':' + u.port : ''));
        } catch (_) {}
      }
      return out;
    }
    function czHtml(pathOrUrl) {
      var list = expandCzHosts();
      var sawChallenge = false;
      for (var i = 0; i < list.length; i++) {
        var hostBase = list[i];
        var u = address(pathOrUrl, hostBase + '/').url;
        var r = httpReqSoft(u, { timeout: 5000, headers: { 'User-Agent': cfg.userAgent, 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: hostBase + '/' } });
        if (r.challenge) sawChallenge = true;
        if (r.ok) {
          czHost = hostBase;
          return r.content;
        }
      }
      fail(sawChallenge ? 'drpy_verification_required' : 'drpy_source_unavailable');
    }
    function czList(html) {
      return pdfa(html, 'div.bt_img.mi_ne_kd > ul > li').map(function (li) {
        var href = pdfh(li, 'a&&href');
        var name = pdfh(li, 'h3.dytit a&&Text') || pdfh(li, 'img&&alt');
        if (!href || !name) return null;
        return {
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(li, 'img&&data-original') || pdfh(li, 'img&&src'), czHost + '/'),
          vod_remarks: pdfh(li, 'div.hdinfo > span&&Text') || pdfh(li, 'div.jidi > span&&Text')
        };
      }).filter(Boolean);
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '/movie_bt_series/dyy', type_name: '电影' },
          { type_id: '/movie_bt_series/dianshiju', type_name: '电视剧' },
          { type_id: '/movie_bt_series/guochanju', type_name: '国产剧' },
          { type_id: '/movie_bt_series/mj', type_name: '美剧' },
          { type_id: '/movie_bt_series/hj', type_name: '韩剧' },
          { type_id: '/movie_bt_series/rj', type_name: '日剧' },
          { type_id: '/dongmanjuchangban', type_name: '动漫' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      return { list: czList(czHtml(czHost + '/')) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var path = str(tid).replace(/\/+$/, '') + (page > 1 ? ('/page/' + page) : '');
      var list = czList(czHtml(path));
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 25, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var r = httpReq(cfg.searchApi + encodeURIComponent(kw), { headers: { 'User-Agent': cfg.userAgent } });
      var lines = str(r.content).trim().split('$$$').filter(Boolean);
      var list = lines.map(function (row) {
        var cols = row.split('|');
        if (cols.length < 2) return null;
        return {
          vod_id: czHost + '/movie/' + cols[0].trim() + '.html',
          vod_name: cols[1].trim(),
          vod_pic: safePic(cols[2] || '', czHost + '/'),
          vod_remarks: (cols[3] || '').trim()
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var html = czHtml(id);
      var eps = pdfa(html, 'div.paly_list_btn a').map(function (a) {
        var h = pdfh(a, 'a&&href'), t = pdfh(a, 'a&&Text');
        return (h && t) ? (t.replace(/[$#]/g, ' ').trim() + '$' + h) : '';
      }).filter(Boolean);
      return {
        list: [{
          vod_id: str(id),
          vod_name: pdfh(html, 'div.dytext h1&&Text') || pdfh(html, 'h1&&Text') || str(id),
          vod_pic: safePic(pdfh(html, 'div.dyimg img&&src'), czHost + '/'),
          vod_content: stripHtml(pdfh(html, 'div.yp_context&&Html')),
          vod_play_from: eps.length ? '厂长直连' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var html = czHtml(id);
      var dncry = /"([^"]+)";var [\d\w]+=function dncry.*?Utf8\.parse\("([\d\w]+)".*?Utf8\.parse\(([\d]+)\)/.exec(html);
      if (dncry) {
        var decHtml = aesCbcDecryptText(dncry[1], dncry[2], dncry[3]);
        var uMatch = /url:\s*["']([^"']+)["']/.exec(decHtml) || /(https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)/i.exec(decHtml);
        if (uMatch && uMatch[1]) {
          return { parse: 0, url: address(uMatch[1]).url, header: { 'User-Agent': cfg.playUa, Referer: czHost + '/' } };
        }
      }
      var iframeSrc = pdfh(html, 'iframe&&src');
      if (iframeSrc) {
        var iUrl = address(iframeSrc, czHost + '/').url;
        var pHtml = httpReq(iUrl, { headers: { 'User-Agent': cfg.playUa, Referer: czHost + '/' } }).content;
        var czFun = /result_v2\s*=\s*(\{[^;]+\})/.exec(pHtml);
        if (czFun) {
          try {
            var rObj = JSON.parse(czFun[1]);
            if (rObj.data) {
              var hexRev = rObj.data.split('').reverse().join('');
              var rawUrl = '';
              for (var i = 0; i < hexRev.length; i += 2) rawUrl += String.fromCharCode(parseInt(hexRev.substr(i, 2), 16));
              var mid = (rawUrl.length - 7) / 2;
              var finalU = rawUrl.substring(0, mid) + rawUrl.substring(mid + 7);
              if (/^https?:\/\//i.test(finalU)) return { parse: 0, url: address(finalU).url, header: { 'User-Agent': cfg.playUa } };
            }
          } catch (_) {}
        }
        var m3u8 = /["'](https?:\/\/[^"']+\.(?:m3u8|mp4)[^"']*)["']/i.exec(pHtml);
        if (m3u8 && m3u8[1]) return { parse: 0, url: address(m3u8[1]).url, header: { 'User-Agent': cfg.playUa, Referer: iUrl } };
      }
      var direct = /["'](https?:\/\/[^"']+\.(?:m3u8|mp4)[^"']*)["']/i.exec(html);
      if (direct && direct[1]) return { parse: 0, url: address(direct[1]).url, header: { 'User-Agent': cfg.playUa, Referer: czHost + '/' } };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 8. libvio-v1 (Libvio) ====================
  if (cfg.adapter === 'libvio-v1') {
    var lvHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    var lvHeaders = { Referer: lvHost + '/' };
    var hbLines = str(cfg.headersBlock).split('\n');
    for (var hi = 0; hi + 1 < hbLines.length; hi += 2) {
      lvHeaders[hbLines[hi].trim()] = hbLines[hi + 1].trim();
    }
    function lvHtml(pathOrUrl) {
      var u = address(pathOrUrl, lvHost + '/').url;
      var r = httpReq(u, { headers: lvHeaders });
      if (r.code < 200 || r.code >= 400) fail();
      return r.content;
    }
    function lvList(html) {
      return pdfa(html, 'ul.stui-vodlist li').map(function (li) {
        var a = pdfh(li, 'a.stui-vodlist__thumb&&href') || pdfh(li, 'h4 a&&href');
        var title = pdfh(li, 'a.stui-vodlist__thumb&&title') || pdfh(li, 'h4 a&&Text');
        if (!a || !title) return null;
        return {
          vod_id: a,
          vod_name: title,
          vod_pic: safePic(pdfh(li, 'a.stui-vodlist__thumb&&data-original') || pdfh(li, 'img&&src'), lvHost + '/'),
          vod_remarks: pdfh(li, 'span.pic-text&&Text')
        };
      }).filter(Boolean);
    }
    __drpy.home = function () {
      var html = lvHtml(lvHost + '/');
      var classes = [];
      pdfa(html, 'ul.stui-header__menu li a').forEach(function (a) {
        var href = pdfh(a, 'a&&href'), text = pdfh(a, 'a&&Text');
        var m = /\/type\/(\d+)\.html/.exec(href);
        if (m && text) classes.push({ type_id: m[1], type_name: text });
      });
      if (!classes.length) {
        classes = [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '剧集' },
          { type_id: '4', type_name: '动漫' },
          { type_id: '15', type_name: '日韩剧' },
          { type_id: '16', type_name: '欧美剧' }
        ];
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      return { list: lvList(lvHtml(lvHost + '/')) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var list = lvList(lvHtml('/show/' + encodeURIComponent(str(tid)) + '--------' + page + '---.html'));
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 10, total: 0, list: [] };
      var r = httpReq(lvHost + '/index.php/ajax/suggest?mid=1&wd=' + encodeURIComponent(kw) + '&limit=10&timestamp=' + Date.now(), { headers: lvHeaders });
      var doc; try { doc = JSON.parse(r.content); } catch (_) { return { page: 1, pagecount: 1, limit: 10, total: 0, list: [] }; }
      var arr = isObj(doc) && Array.isArray(doc.list) ? doc.list : [];
      var list = arr.map(function (it) {
        if (!isObj(it) || !it.id || !it.name) return null;
        return {
          vod_id: '/detail/' + it.id + '.html',
          vod_name: str(it.name),
          vod_pic: safePic(it.pic, lvHost + '/'),
          vod_remarks: ''
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: 10, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var html = lvHtml(id);
      var panels = pdfa(html, 'div.stui-vodlist__head');
      if (!panels.length) panels = pdfa(html, 'div.playlist-panel');
      var froms = [], groups = [];
      panels.forEach(function (panel, idx) {
        var head = pdfh(panel, 'h3&&Text') || pdfh(panel, 'div.panel-head&&Text') || ('线路' + (idx + 1));
        if (/下载|字幕/.test(head)) return;
        var eps = [];
        pdfa(panel, 'ul li a').forEach(function (a) {
          var h = pdfh(a, 'a&&href'), t = pdfh(a, 'a&&Text');
          if (!h || !t) return;
          if (isPanShare(h)) {
            eps.push(t.replace(/[$#]/g, ' ').trim() + '$mmshare://' + h);
          } else {
            eps.push(t.replace(/[$#]/g, ' ').trim() + '$' + h);
          }
        });
        if (eps.length) {
          froms.push(head.trim());
          groups.push(eps.join('#'));
        }
      });
      return {
        list: [{
          vod_id: str(id),
          vod_name: pdfh(html, 'h1.title&&Text') || pdfh(html, 'h1&&Text') || str(id),
          vod_pic: safePic(pdfh(html, 'div.stui-content__thumb img&&data-original') || pdfh(html, 'div.stui-content__thumb img&&src'), lvHost + '/'),
          vod_content: stripHtml(pdfh(html, 'span.detail-content&&Html') || pdfh(html, 'p.desc&&Html')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: groups.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (isDirectMedia(id)) return { parse: 0, url: address(id, lvHost + '/').url, header: { 'User-Agent': cfg.playUa, Referer: lvHost + '/' } };
      var html = lvHtml(id);
      var pMatch = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</.exec(html);
      if (pMatch) {
        var pData = JSON.parse(pMatch[1]);
        var rawU = str(pData.url).trim();
        if (pData.encrypt === 1 || pData.encrypt === '1') rawU = unescape(rawU);
        else if (pData.encrypt === 2 || pData.encrypt === '2') rawU = unescape(b64ToUtf8(rawU));
        if (isPanShare(rawU)) fail('drpy_media_protocol');
        if (isDirectMedia(rawU)) return { parse: 0, url: address(rawU, lvHost + '/').url, header: { 'User-Agent': cfg.playUa, Referer: lvHost + '/' } };
        var fromCode = str(pData.from);
        var jxPaths = [lvHost + '/vid/plyr/vr2.php?url=', lvHost + '/vid/ty4.php?url=', lvHost + '/vid/yd.php?url='];
        if (fromCode) jxPaths.unshift(lvHost + '/vid/' + fromCode + '.php?url=');
        for (var i = 0; i < jxPaths.length; i++) {
          try {
            var jr = req(jxPaths[i] + encodeURIComponent(rawU), { timeout: 6000, headers: { 'User-Agent': cfg.playUa, Referer: lvHost + '/' } });
            if (jr && jr.code >= 200 && jr.code < 300 && typeof jr.content === 'string') {
              var m = /urls\s*=\s*['"](https?:\/\/[^'"]+)['"]/i.exec(jr.content) || /["'](https?:\/\/[^"']+\.(?:m3u8|mp4)[^"']*)["']/i.exec(jr.content);
              if (m && m[1]) return { parse: 0, url: address(m[1]).url, header: { 'User-Agent': cfg.playUa, Referer: lvHost + '/' } };
            }
          } catch (_) {}
        }
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 9. ygp-v1 (YGP / 预告片) ====================
  if (cfg.adapter === 'ygp-v1') {
    var ygHost = str(cfg.defaultHost).replace(/\/+$/, '');
    var ygHeaders = { 'User-Agent': cfg.userAgent, 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: ygHost + '/' };
    function ygHtml(pathOrUrl) {
      var u = address(pathOrUrl, ygHost + '/').url;
      var r = httpReq(u, { headers: ygHeaders });
      if (r.code < 200 || r.code >= 400) fail();
      return r.content;
    }
    function ygList(html) {
      var items = pdfa(html, 'div.m_list div.item');
      if (!items.length) items = pdfa(html, 'ul.mov_list li');
      if (!items.length) items = pdfa(html, 'div.box-item');
      return items.map(function (it) {
        var href = pdfh(it, 'a&&href');
        var name = pdfh(it, 'h3&&Text') || pdfh(it, 'a&&title') || pdfh(it, 'p&&Text');
        if (!href || !name) return null;
        return {
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(it, 'img&&src'), ygHost + '/'),
          vod_remarks: pdfh(it, 'span&&Text')
        };
      }).filter(Boolean);
    }
    __drpy.home = function () {
      var filters = {};
      try { filters = JSON.parse(cfg.filtersJson); } catch (_) {}
      return {
        class: [
          { type_id: 'allmovies', type_name: '最新预告' }
        ],
        filters: filters
      };
    };
    __drpy.homeVod = function () {
      return { list: ygList(ygHtml(ygHost + '/')) };
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var list = ygList(ygHtml(ygHost + '/' + str(tid).replace(/^\/+/, '') + '?page=' + page));
      return { page: page, pagecount: list.length ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var list = ygList(ygHtml(ygHost + '/?keyword=' + encodeURIComponent(kw) + '&view=search'));
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var html = ygHtml(id);
      var eps = [];
      pdfa(html, 'div.tlist-bbs-tdtitle a, video source, a[href*="play"]').forEach(function (el, idx) {
        var h = pdfh(el, 'source&&src') || pdfh(el, 'a&&href');
        var t = pdfh(el, 'a&&Text') || ('预告片' + (idx + 1));
        if (h) eps.push(t.replace(/[$#]/g, ' ').trim() + '$' + h);
      });
      if (!eps.length) {
        var vSrc = (/["'](https?:\/\/[^"']+\.mp4[^"']*)["']/i.exec(html) || [])[1];
        if (vSrc) eps.push('预告片$' + vSrc);
      }
      return {
        list: [{
          vod_id: str(id),
          vod_name: pdfh(html, 'h1.movie-name&&Text') || pdfh(html, 'h1&&Text') || str(id),
          vod_pic: safePic(pdfh(html, 'div.inner-wrapper img&&src'), ygHost + '/'),
          vod_content: stripHtml(pdfh(html, 'div.movie-desc&&Html') || pdfh(html, 'p.summary&&Html')),
          vod_play_from: eps.length ? '预告专线' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      if (isDirectMedia(id)) return { parse: 0, url: address(id, ygHost + '/').url, header: ygHeaders };
      var html = ygHtml(id);
      var mp4 = (/["'](https?:\/\/[^"']+\.(?:mp4|m3u8)[^"']*)["']/i.exec(html) || [])[1];
      if (mp4) return { parse: 0, url: address(mp4).url, header: ygHeaders };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 10. jumitv-v1 (JumiTv) ====================
  if (cfg.adapter === 'jumitv-v1') {
    var jmHosts = (Array.isArray(cfg.apiHosts) && cfg.apiHosts.length ? cfg.apiHosts : []).slice();
    var jmPlayHosts = (Array.isArray(cfg.playHosts) && cfg.playHosts.length ? cfg.playHosts : []).slice();
    var jmUa = str(cfg.userAgent || 'okhttp/3.12.11');
    var jmHeaders = { 'User-Agent': jmUa };
    function rc4HexDecrypt(rawText, keyStr) {
      var s = str(rawText).replace(/^\uFEFF/, '').trim();
      if (!s) return '';
      if (s.charAt(0) === '{' || s.charAt(0) === '[') return s;
      var hex = s.replace(/\s+/g, '');
      if (!/^[0-9a-fA-F]+$/.test(hex) || (hex.length & 1) !== 0) return s;
      var key = [], i;
      for (i = 0; i < keyStr.length; i++) key.push(keyStr.charCodeAt(i) & 0xff);
      var box = new Array(256);
      for (i = 0; i < 256; i++) box[i] = i;
      var j = 0, tmp;
      for (i = 0; i < 256; i++) {
        j = (j + box[i] + key[i % key.length]) & 255;
        tmp = box[i]; box[i] = box[j]; box[j] = tmp;
      }
      var len = hex.length >> 1;
      var out = new Uint8Array(len);
      var a = 0, b = 0;
      for (i = 0; i < len; i++) {
        a = (a + 1) & 255;
        b = (b + box[a]) & 255;
        tmp = box[a]; box[a] = box[b]; box[b] = tmp;
        var byteVal = parseInt(hex.substr(i * 2, 2), 16);
        out[i] = byteVal ^ box[(box[a] + box[b]) & 255];
      }
      if (typeof TextDecoder === 'function') {
        try { return new TextDecoder('utf-8').decode(out); } catch (_) {}
      }
      var bin = '';
      for (i = 0; i < out.length; i++) bin += String.fromCharCode(out[i]);
      try { return decodeURIComponent(escape(bin)); } catch (_) { return bin; }
    }
    function jmApi(path) {
      var list = jmHosts.length ? jmHosts : [str(cfg.origin).replace(/^https?:\/\//i, '').replace(/:\d+$/, '')];
      var scheme = str(cfg.scheme || 'http://');
      var port = str(cfg.apiPort || ':1122');
      var prefix = str(cfg.apiPrefix || '/api.php/localhost');
      for (var i = 0; i < list.length; i++) {
        var h = str(list[i]).trim();
        if (!h) continue;
        var u = scheme + h + port + prefix + path;
        var r = httpReqSoft(u, { headers: jmHeaders, timeout: 5500 });
        if (r && r.ok && str(r.content)) {
          var dec = rc4HexDecrypt(r.content, str(cfg.rc4Key));
          try {
            var doc = JSON.parse(dec);
            if (i > 0) {
              jmHosts.splice(i, 1);
              jmHosts.unshift(h);
            }
            return doc;
          } catch (_) {}
        }
      }
      fail('drpy_source_unavailable');
    }
    function jmMapList(arr) {
      if (!Array.isArray(arr)) return [];
      return arr.map(function (it) {
        if (!isObj(it)) return null;
        var nl = str(it.nextlink);
        var idM = /ids=(\d+)/.exec(nl);
        var id = idM ? idM[1] : (/^\d+$/.test(nl) ? nl : str(it.id));
        if (!id) return null;
        return {
          vod_id: id,
          vod_name: str(it.title),
          vod_pic: safePic(it.pic),
          vod_remarks: str(it.state)
        };
      }).filter(Boolean);
    }
    function jmMapTop(arr) {
      if (!Array.isArray(arr)) return [];
      return arr.map(function (it) {
        if (!isObj(it) || !it.id) return null;
        return {
          vod_id: String(it.id),
          vod_name: str(it.tjinfo),
          vod_pic: safePic(it.tjpicurl),
          vod_remarks: ''
        };
      }).filter(Boolean);
    }
    function jmFilters() {
      try {
        var raw = jmApi(str(cfg.flitterPath));
        if (!isObj(raw)) return {};
        var out = {};
        var keys = Object.keys(raw);
        for (var i = 0; i < keys.length; i++) {
          var k = keys[i];
          var groups = raw[k];
          if (!Array.isArray(groups)) continue;
          var arr = [];
          for (var g = 0; g < groups.length; g++) {
            var grp = groups[g];
            if (!isObj(grp) || !str(grp.field)) continue;
            var vals = [{ n: '全部', v: '' }];
            if (Array.isArray(grp.values)) {
              for (var v = 0; v < grp.values.length; v++) {
                var val = str(grp.values[v]);
                if (val) vals.push({ n: val, v: val });
              }
            }
            arr.push({ key: str(grp.field), name: str(grp.name), value: vals });
          }
          if (arr.length) out[k] = arr;
        }
        return out;
      } catch (_) { return {}; }
    }
    __drpy.home = function () {
      var ts = String(Date.now());
      var cats = jmApi(str(cfg.catPath) + ts + '&tt=' + ts);
      var classes = [];
      if (Array.isArray(cats)) {
        for (var i = 0; i < cats.length; i++) {
          var c = cats[i];
          if (!isObj(c) || Number(c.type_status) === 0) continue;
          var tid = str(c.type_en || c.type_id);
          var tname = str(c.type_name);
          if (tid && tname) classes.push({ type_id: tid, type_name: tname });
        }
      }
      var list = [];
      try {
        var topDoc = jmApi(str(cfg.topPath));
        list = jmMapTop(topDoc && topDoc.data);
      } catch (_) {}
      return { class: classes, list: list, filters: jmFilters() };
    };
    __drpy.homeVod = function () {
      var topDoc = jmApi(str(cfg.topPath));
      return { list: jmMapTop(topDoc && topDoc.data) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var cid = str(tid || '1');
      var path = str(cfg.listPath) + encodeURIComponent(cid) + '&page=' + page;
      if (isObj(extend)) {
        var eKeys = Object.keys(extend);
        for (var i = 0; i < eKeys.length; i++) {
          var ek = eKeys[i];
          if (ek === 'filters' || !str(extend[ek])) continue;
          path += '&' + encodeURIComponent(ek) + '=' + encodeURIComponent(str(extend[ek]));
        }
      }
      var doc = jmApi(path);
      var list = jmMapList(doc && doc.data);
      var pc = (doc && Number(doc.totalpage)) || (list.length >= 12 ? page + 1 : page);
      return { page: page, pagecount: pc, limit: 20, total: (doc && Number(doc.videonum)) || list.length, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var doc = jmApi(str(cfg.searchPath) + encodeURIComponent(kw) + '&page=' + page);
      var list = jmMapList(doc && doc.data);
      var pc = (doc && Number(doc.totalpage)) || (list.length >= 12 ? page + 1 : page);
      return { page: page, pagecount: pc, limit: 20, total: (doc && Number(doc.videonum)) || list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var doc = jmApi(str(cfg.detailPath) + encodeURIComponent(str(vid)));
      if (!isObj(doc)) fail('drpy_source_unavailable');
      var showMap = {};
      var playerArr = doc.player;
      if (typeof playerArr === 'string' && playerArr) {
        try { playerArr = JSON.parse(rc4HexDecrypt(playerArr, str(cfg.rc4Key))); } catch (_) { playerArr = []; }
      }
      if (Array.isArray(playerArr)) {
        for (var p = 0; p < playerArr.length; p++) {
          var pl = playerArr[p];
          if (isObj(pl) && str(pl.from)) showMap[str(pl.from)] = str(pl.show || pl.from);
        }
      }
      var froms = [], urls = [];
      if (isObj(doc.videolist)) {
        var vKeys = Object.keys(doc.videolist);
        for (var k = 0; k < vKeys.length; k++) {
          var fk = vKeys[k];
          var epsArr = doc.videolist[fk];
          if (!Array.isArray(epsArr) || !epsArr.length) continue;
          var eps = [];
          for (var e = 0; e < epsArr.length; e++) {
            var ep = epsArr[e];
            if (isObj(ep) && str(ep.url)) {
              eps.push((str(ep.title) || ('第' + (e + 1) + '集')).replace(/[$#]/g, ' ') + '$' + str(ep.url));
            }
          }
          if (eps.length) {
            froms.push(showMap[fk] || fk);
            urls.push(eps.join('#'));
          }
        }
      }
      function joinField(val) {
        if (Array.isArray(val)) return val.map(str).filter(Boolean).join(',');
        return str(val);
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(doc.title),
          vod_pic: safePic(doc.img_url),
          type_name: joinField(doc.type),
          vod_year: str(doc.pubtime),
          vod_area: joinField(doc.area),
          vod_remarks: str(doc.trunk),
          vod_actor: joinField(doc.actor),
          vod_director: joinField(doc.director),
          vod_content: str(doc.intro),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var s = str(id).trim();
      if (!s) fail('drpy_media_unresolved');
      var scheme = str(cfg.playScheme || 'http://');
      var portPath = str(cfg.playPortPath || ':6001/Client/?url=');
      var appVal = str(cfg.playApp || '10000');
      for (var i = 0; i < jmPlayHosts.length; i++) {
        var h = str(jmPlayHosts[i]).trim();
        if (!h) continue;
        var api = scheme + h + portPath + encodeURIComponent(s);
        var body = 'app=' + encodeURIComponent(appVal) + '&key=' + encodeURIComponent(String(Date.now()));
        var r = httpReqSoft(api, {
          method: 'POST',
          data: body,
          headers: { 'User-Agent': jmUa, 'Content-Type': 'application/x-www-form-urlencoded' },
          timeout: 6500
        });
        if (r && r.ok && str(r.content)) {
          try {
            var decPlay = rc4HexDecrypt(r.content, str(cfg.rc4Key));
            var pd = JSON.parse(decPlay);
            var playUrl = str(pd && pd.url).trim();
            if (/^https?:\/\//i.test(playUrl)) {
              return { parse: 0, url: address(playUrl).url, header: jmHeaders };
            }
          } catch (_) {}
        }
      }
      if (/^https?:\/\//i.test(s) && isDirectMedia(s)) {
        return { parse: 0, url: address(s).url, header: jmHeaders };
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  fail('drpy_source_unavailable');
}

module.exports = function ftyVodRule(config) {
  if (!config || !VOD_ADAPTERS.includes(config.adapter) || !/^https?:\/\//.test(config.origin)) {
    throw Error('endpoint configuration required');
  }
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:10000,预处理:"js:rule._install();",_install:' + installFtyVod.toString() + '};';
};

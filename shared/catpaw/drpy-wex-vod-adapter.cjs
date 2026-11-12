// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';

const { VOD_WEX_ADAPTERS } = require('./drpy-wex-extractor.cjs');

function installWexVod() {
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
  function md5Hex(s) { return CryptoJS.MD5(str(s)).toString(); }
  function sha1Hex(s) { return CryptoJS.SHA1(str(s)).toString(); }
  function sha256Hex(s) { return CryptoJS.SHA256(str(s)).toString(); }
  function aesCbcDecryptText(cipherB64, keyStr, ivStr) {
    var clean = str(cipherB64).trim().replace(/\\/g, '').replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    var algo = keyStr.length > 16 ? 'aes-256-cbc' : 'aes-128-cbc';
    var out = nodeCipher('decrypt', algo, utf8ToB64(keyStr), utf8ToB64(ivStr), clean, '');
    return b64ToUtf8(out.data);
  }
  function aesCbcEncryptB64(plainStr, keyStr, ivStr) {
    var algo = keyStr.length > 16 ? 'aes-256-cbc' : 'aes-128-cbc';
    return nodeCipher('encrypt', algo, utf8ToB64(keyStr), utf8ToB64(ivStr), utf8ToB64(plainStr), '').data;
  }
  function aesEcbDecryptText(cipherB64, keyStr) {
    var clean = str(cipherB64).trim().replace(/\\/g, '').replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    var algo = keyStr.length > 16 ? 'aes-256-ecb' : 'aes-128-ecb';
    var out = nodeCipher('decrypt', algo, utf8ToB64(keyStr), '', clean, '');
    return b64ToUtf8(out.data);
  }
  function aesEcbEncryptB64(plainStr, keyStr) {
    var algo = keyStr.length > 16 ? 'aes-256-ecb' : 'aes-128-ecb';
    return nodeCipher('encrypt', algo, utf8ToB64(keyStr), '', utf8ToB64(plainStr), '').data;
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
  function randomChars(len, alphabet) {
    var arr = new Uint8Array(len);
    crypto.getRandomValues(arr);
    var out = '';
    for (var i = 0; i < len; i++) out += alphabet.charAt(arr[i] % alphabet.length);
    return out;
  }
  function parseJsonSafe(raw) {
    var t = str(raw).replace(/^\uFEFF/, '').trim();
    if (!t) return null;
    try { return JSON.parse(t); } catch (_) {
      var end = Math.max(t.lastIndexOf('}'), t.lastIndexOf(']'));
      if (end > 0) {
        try { return JSON.parse(t.slice(0, end + 1)); } catch (_2) {}
      }
      return null;
    }
  }
  function httpReq(url, opts) {
    var target = address(url).url;
    var o = Object.assign({ timeout: 10000 }, opts || {});
    if (o.headers) o.headers = cleanHeaders(o.headers);
    var r;
    try { r = req(target, o); }
    catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    if (!r || typeof r.content !== 'string') fail('drpy_source_unavailable');
    checkChallenge(r.content);
    return r;
  }
  function httpReqSoft(url, opts) {
    try {
      var target = address(url).url;
      var o = Object.assign({ timeout: 6000 }, opts || {});
      if (o.headers) o.headers = cleanHeaders(o.headers);
      var r = req(target, o);
      if (!r || typeof r.content !== 'string') return null;
      checkChallenge(r.content);
      return r;
    } catch (e) {
      if (e && e.message === 'drpy_verification_required') fail('drpy_verification_required');
      return null;
    }
  }
  function isDirectMedia(u) {
    return /^https?:\/\/[^?#]+\.(?:m3u8|mp4|flv|mpd|mkv|ts|mp3|m4a)(?:[?#]|$)/i.test(str(u).trim());
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
    if (isObj(cached) && Number(cached.exp) > Date.now() && str(cached.siteUrl)) return cached;
    var rHeaders = { 'User-Agent': str(cfg.remoteUa || cfg.userAgent || 'Mozilla/5.0'), Accept: 'application/json,text/plain,*/*' };
    var apiUrls = [cfg.apiTxt0, cfg.apiTxt1, cfg.apiTxt2, cfg.apiTxt3].map(str).filter(Boolean);
    var siteUrl = '';
    for (var i = 0; i < apiUrls.length; i++) {
      var r = httpReqSoft(apiUrls[i], { headers: rHeaders, timeout: 4500 });
      if (r && r.code >= 200 && r.code < 300) {
        var dec = decryptRemoteText(r.content).split(/[\r\n]+/)[0].trim().replace(/\/+$/, '');
        if (/^https?:\/\//i.test(dec)) { siteUrl = dec; break; }
      }
    }
    var siteConfig = {};
    var itemUrls = [cfg.itemTxt0, cfg.itemTxt1, cfg.itemTxt2].map(str).filter(Boolean);
    for (var j = 0; j < itemUrls.length; j++) {
      var ir = httpReqSoft(itemUrls[j], { headers: rHeaders, timeout: 4500 });
      if (ir && ir.code >= 200 && ir.code < 300) {
        var itemObj = parseJsonSafe(decryptRemoteText(ir.content));
        if (isObj(itemObj)) {
          var csUrl = str(itemObj.config_site).trim();
          if (/^https?:\/\//i.test(csUrl)) {
            var sr = httpReqSoft(csUrl, { headers: rHeaders, timeout: 4500 });
            if (sr && sr.code >= 200 && sr.code < 300) {
              var sc = parseJsonSafe(decryptRemoteText(sr.content));
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
  function pickSiteHosts(siteKey, fallbacks) {
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
    if (siteKey && cfg.apiTxt0) {
      var rc = loadRemoteWexConfig();
      var entry = rc && isObj(rc.siteConfig) ? rc.siteConfig[siteKey] : null;
      if (Array.isArray(entry)) {
        for (var k = 0; k < entry.length; k++) pushHost(entry[k]);
      } else if (typeof entry === 'string') {
        var ep = entry.split(/[|,;\s]+/);
        for (var m = 0; m < ep.length; m++) pushHost(ep[m]);
      }
    }
    if (Array.isArray(fallbacks)) {
      for (var f = 0; f < fallbacks.length; f++) pushHost(fallbacks[f]);
    }
    if (!list.length) pushHost(cfg.origin);
    return list;
  }
  function encodeEp(obj) { return 'ep1:' + utf8ToB64(JSON.stringify(obj)); }
  function decodeEp(raw) {
    var s = str(raw).trim();
    if (s.indexOf('ep1:') === 0) {
      var p = parseJsonSafe(b64ToUtf8(s.slice(4)));
      if (isObj(p)) return p;
    }
    return null;
  }

  // =========================================================================
  // 1. wexappv7-v1 (WexAppV7 — 师兄/粉猪/咸鱼/追剧/柚子)
  // =========================================================================
  if (cfg.adapter === 'wexappv7-v1') {
    var v7State = null;
    function v7EnsureConfig() {
      if (v7State) return v7State;
      var extObj = isObj(cfg.ext) ? cfg.ext : {};
      var nested = isObj(extObj.ext) ? extObj.ext : {};
      var configKey = str(extObj.config || nested.config).trim();
      if (!configKey && str(cfg.extText) && str(cfg.extText).indexOf('{') !== 0 && !/^https?:\/\//i.test(str(cfg.extText))) {
        configKey = str(cfg.extText).trim();
      }
      if (!configKey) configKey = 'AppV7Dsx';
      var cryptoUrl = str(extObj.crypto || nested.crypto).trim();
      if (!/^https?:\/\//i.test(cryptoUrl)) {
        var rc = loadRemoteWexConfig();
        if (!rc.mySiteUrl) fail('drpy_source_unavailable');
        cryptoUrl = rc.mySiteUrl.replace(/\/+$/, '') + '/appv7/crypto.php';
      }
      var sep = cryptoUrl.indexOf('?') >= 0 ? '&' : '?';
      var r = httpReq(cryptoUrl + sep + 'action=config&key=' + encodeURIComponent(configKey), {
        headers: { 'User-Agent': str(cfg.remoteUa || 'okhttp/4.12.0'), Accept: 'application/json,*/*' }
      });
      var doc = parseJsonSafe(r.content);
      var d = isObj(doc) && isObj(doc.data) ? doc.data : doc;
      if (!isObj(d) || !str(d.host) || !str(d.key)) fail('drpy_source_response');
      v7State = { cryptoUrl: cryptoUrl, cfg: d };
      return v7State;
    }
    function v7CryptoAction(action, bodyObj) {
      var st = v7EnsureConfig();
      var sep = st.cryptoUrl.indexOf('?') >= 0 ? '&' : '?';
      var r = httpReq(st.cryptoUrl + sep + 'action=' + encodeURIComponent(action), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': str(cfg.remoteUa || 'okhttp/4.12.0') },
        body: JSON.stringify(bodyObj)
      });
      var doc = parseJsonSafe(r.content);
      if (!isObj(doc)) fail('drpy_source_response');
      return isObj(doc.data) ? doc.data : doc;
    }
    function v7Call(method, dataObj) {
      var st = v7EnsureConfig();
      var c = st.cfg;
      var rawPayload = JSON.stringify({ method: method, data: dataObj || {}, csrf: Date.now() });
      var encRes = v7CryptoAction('encrypt', { key: str(c.key), raw: rawPayload });
      var encBody = str(encRes.body || encRes.raw || encRes.result || encRes.data);
      if (!encBody) fail('drpy_source_response');
      var apiUrl = str(c.host).replace(/\/+$/, '') + '/v7/logs';
      var r = httpReq(apiUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'User-Agent': str(c.user_agent || 'okhttp/4.12.0'),
          version: str(c.version),
          'version-number': str(c.version_number),
          'pk-id': str(c.pk_id),
          'build-time': str(c.build_time),
          platform: str(c.platform || 'android'),
          'platform-version': str(c.platform_version || '12')
        },
        body: encBody
      });
      var text = str(r.content).trim();
      var parsed = text.indexOf('{') === 0 ? parseJsonSafe(text) : null;
      if (!isObj(parsed)) {
        var decRes = v7CryptoAction('decrypt', { key: str(c.key), raw: text });
        var decRaw = decRes.raw || decRes.body || decRes.result || decRes;
        parsed = typeof decRaw === 'string' ? parseJsonSafe(decRaw) : (isObj(decRaw) ? decRaw : null);
      }
      if (!isObj(parsed)) fail('drpy_source_response');
      return parsed;
    }
    function v7Card(it, baseHost) {
      if (!isObj(it)) return null;
      var id = str(it.vod_id || it.id).trim();
      var name = str(it.vod_name || it.name || it.title).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vod_pic || it.pic || it.cover, baseHost + '/'),
        vod_remarks: str(it.vod_remarks || it.vod_version || it.remarks).trim()
      };
    }
    __drpy.home = function () {
      var st = v7EnsureConfig();
      var res = v7Call('nav', {});
      var arr = Array.isArray(res.data) ? res.data : (isObj(res.data) && Array.isArray(res.data.list) ? res.data.list : []);
      var classes = [];
      var filters = {};
      for (var i = 0; i < arr.length; i++) {
        var row = arr[i];
        if (!isObj(row)) continue;
        var tid = str(row.type_id).trim();
        var tname = str(row.type_name).trim();
        if (!tid || !tname) continue;
        classes.push({ type_id: tid, type_name: tname });
        var te = isObj(row.type_extend) ? row.type_extend : {};
        var defs = [];
        var fields = [['class', '剧情'], ['area', '地区'], ['lang', '语言'], ['year', '年份']];
        for (var f = 0; f < fields.length; f++) {
          var fk = fields[f][0], fn = fields[f][1];
          var rawVals = str(te[fk]).split(',').map(function (x) { return x.trim(); }).filter(Boolean);
          if (rawVals.length) {
            defs.push({
              key: fk, name: fn,
              value: [{ n: '全部', v: '' }].concat(rawVals.map(function (x) { return { n: x, v: x }; }))
            });
          }
        }
        defs.push({
          key: 'order', name: '排序',
          value: [{ n: '最新', v: '最新' }, { n: '最热', v: '最热' }, { n: '评分', v: '评分' }]
        });
        filters[tid] = defs;
      }
      return { class: classes, filters: filters };
    };
    __drpy.homeVod = function () {
      var st = v7EnsureConfig();
      var host = str(st.cfg.host).replace(/\/+$/, '');
      var nav = v7Call('nav', {});
      var arr = Array.isArray(nav.data) ? nav.data : [];
      var firstTid = arr.length && isObj(arr[0]) ? str(arr[0].type_id) : '1';
      var res = v7Call('video_list', { pg: 1, tid: Number(firstTid) || firstTid, class: '', area: '', lang: '', year: '', order: '最新' });
      var rows = Array.isArray(res.data) ? res.data : (isObj(res.data) && Array.isArray(res.data.list) ? res.data.list : []);
      return { list: rows.map(function (x) { return v7Card(x, host); }).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var st = v7EnsureConfig();
      var host = str(st.cfg.host).replace(/\/+$/, '');
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var res = v7Call('video_list', {
        pg: page,
        tid: /^\d+$/.test(str(tid)) ? Number(tid) : str(tid),
        class: str(ext.class),
        area: str(ext.area),
        lang: str(ext.lang),
        year: str(ext.year),
        order: str(ext.order || '最新')
      });
      var rows = Array.isArray(res.data) ? res.data : (isObj(res.data) && Array.isArray(res.data.list) ? res.data.list : []);
      var list = rows.map(function (x) { return v7Card(x, host); }).filter(Boolean);
      var pagecount = Number(res.pagecount) || (list.length >= 12 ? page + 1 : page);
      return { page: page, pagecount: pagecount, limit: 20, total: Number(res.total) || 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var st = v7EnsureConfig();
      var host = str(st.cfg.host).replace(/\/+$/, '');
      var page = Math.max(1, Number(pg) || 1);
      var res = v7Call('search', { pg: page, text: kw });
      var rows = Array.isArray(res.data) ? res.data : (isObj(res.data) && Array.isArray(res.data.list) ? res.data.list : []);
      var list = rows.map(function (x) { return v7Card(x, host); }).filter(Boolean);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var st = v7EnsureConfig();
      var c = st.cfg;
      var host = str(c.host).replace(/\/+$/, '');
      var res = v7Call('video_detail', {
        id: /^\d+$/.test(str(vid)) ? Number(vid) : str(vid),
        sign_md5: str(c.sign_md5),
        apk_path: str(cfg.apkPrefix) + str(c.pk_id) + str(cfg.apkSuffix),
        apk_length: Number(c.apk_length) || 0
      });
      var d = isObj(res.data) ? res.data : res;
      var info = isObj(d.vod_info) ? d.vod_info : d;
      var players = Array.isArray(d.vod_url_with_player) ? d.vod_url_with_player : (Array.isArray(info.vod_url_with_player) ? info.vod_url_with_player : []);
      var froms = [], urls = [];
      for (var i = 0; i < players.length; i++) {
        var pl = players[i];
        if (!isObj(pl) || !str(pl.url)) continue;
        var pName = str(pl.name || pl.code || ('线路' + (i + 1))).replace(/\$\$\$/g, ' ').trim();
        var parts = str(pl.url).split('#');
        var eps = [];
        for (var j = 0; j < parts.length; j++) {
          var seg = parts[j].trim();
          if (!seg) continue;
          var idx = seg.indexOf('$');
          var epName = idx >= 0 ? seg.slice(0, idx).trim() : ('第' + (j + 1) + '集');
          var epUrl = idx >= 0 ? seg.slice(idx + 1).trim() : seg;
          if (!epUrl) continue;
          eps.push(epName.replace(/[$#]/g, ' ') + '$' + encodeEp({
            u: epUrl,
            c: str(pl.code),
            pa: str(pl.parse_api),
            epa: str(pl.extra_parse_api),
            h: isObj(pl.headers) ? pl.headers : null,
            ulf: Array.isArray(pl.un_link_features) ? pl.un_link_features : []
          }));
        }
        if (eps.length) { froms.push(pName); urls.push(eps.join('#')); }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(info.vod_name || info.name),
          vod_pic: safePic(info.vod_pic || info.pic, host + '/'),
          vod_remarks: str(info.vod_remarks),
          vod_year: str(info.vod_year),
          vod_area: str(info.vod_area),
          vod_actor: str(info.vod_actor),
          vod_director: str(info.vod_director),
          vod_content: stripHtml(info.vod_content || info.vod_blurb),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var st = v7EnsureConfig();
      var c = st.cfg;
      var ep = decodeEp(id) || { u: str(id), c: '', pa: '', epa: '', h: null, ulf: [] };
      var rawU = str(ep.u).trim();
      var playHdr = Object.assign({ 'User-Agent': str(c.user_agent || 'okhttp/4.12.0') }, cleanHeaders(ep.h));
      function isUnlinked(u) {
        if (!Array.isArray(ep.ulf)) return false;
        for (var i = 0; i < ep.ulf.length; i++) {
          var feat = str(ep.ulf[i]).trim();
          if (feat && u.indexOf(feat) >= 0) return true;
        }
        return false;
      }
      if (isDirectMedia(rawU) && !isUnlinked(rawU)) {
        return { parse: 0, url: address(rawU).url, header: playHdr };
      }
      try {
        var sec = v7Call('secret_parse_api_url', { token: '', url: rawU, player_code: str(ep.c) });
        var sd = sec.data;
        var su = isObj(sd) ? str(sd.url) : (typeof sd === 'string' ? sd : '');
        if (/^https?:\/\//i.test(su)) return { parse: 0, url: address(su).url, header: playHdr };
      } catch (_) {}
      var parsers = [str(ep.pa), str(ep.epa)].filter(function (x) { return /^https?:\/\//i.test(x); });
      for (var p = 0; p < parsers.length; p++) {
        var pr = httpReqSoft(parsers[p] + encodeURIComponent(rawU), { headers: playHdr, timeout: 8000 });
        if (!pr || pr.code < 200 || pr.code >= 300) continue;
        var pj = parseJsonSafe(pr.content);
        var pu = isObj(pj) ? str(pj.url || (isObj(pj.data) && pj.data.url)) : '';
        if (pu && !/^https?:\/\//i.test(pu) && str(c.parse_key)) {
          try { pu = aesCbcDecryptText(pu, str(c.parse_key).slice(0, 16), str(cfg.playerAesIv)); } catch (_) {}
        }
        if (/^https?:\/\//i.test(pu)) return { parse: 0, url: address(pu).url, header: playHdr };
      }
      if (/^https?:\/\//i.test(rawU)) return { parse: 0, url: address(rawU).url, header: playHdr };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 2. wexguazi-v1 (WexAiGuaZi — 瓜子|秒播)
  // =========================================================================
  if (cfg.adapter === 'wexguazi-v1') {
    var gzHosts = pickSiteHosts('guazi', [cfg.defaultHost, cfg.host1, cfg.host2, cfg.host3, cfg.host4]);
    var gzHost = gzHosts[0];
    function gzRand16() { return randomHex(16).toUpperCase(); }
    function gzJavaHash(text) {
      var n = 0;
      for (var i = 0; i < text.length; i++) n = (Math.imul(n, 31) + text.charCodeAt(i)) | 0;
      return n;
    }
    var gzKey = gzRand16(), gzIv = gzRand16();
    var gzSaved = local.get('wexguazi-v1', 'device');
    var gzState;
    if (isObj(gzSaved) && /^[A-F0-9]{40}$/.test(str(gzSaved.new_key)) && str(gzSaved.old_key)) {
      gzState = gzSaved;
    } else {
      var did = gzRand16(), drand = parseInt(gzRand16().slice(0, 8), 16), dhash = gzJavaHash(did);
      var wa = CryptoJS.lib.WordArray.create([Math.floor(Date.now() / 1000), drand, 0x03000000 | ((dhash >>> 16) & 65535), (dhash & 65535) << 16], 14);
      var chk = gzJavaHash(CryptoJS.HmacSHA1(wa, str(cfg.utdidKey)).toString(CryptoJS.enc.Base64));
      wa.concat(CryptoJS.lib.WordArray.create([chk], 4));
      gzState = { new_key: sha1Hex(did + gzRand16()).toUpperCase(), old_key: wa.toString(CryptoJS.enc.Base64), token: '', registered: false };
      local.set('wexguazi-v1', 'device', gzState);
    }
    function gzDecode(envelope) {
      if (!isObj(envelope) || Number(envelope.code) !== 200 || !isObj(envelope.data)) fail('drpy_source_unavailable');
      var data = envelope.data;
      try {
        var keys = JSON.parse(b64ToUtf8(rsaPkcs1('decrypt', str(cfg.privateKey), str(data.keys))));
        var hex = str(data.response_key).replace(/\\/g, '').trim();
        var plain = CryptoJS.AES.decrypt(
          { ciphertext: CryptoJS.enc.Hex.parse(hex) },
          CryptoJS.enc.Utf8.parse(str(keys.key)),
          { iv: CryptoJS.enc.Utf8.parse(str(keys.iv)), mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 }
        ).toString(CryptoJS.enc.Utf8);
        var parsed = parseJsonSafe(plain);
        if (!isObj(parsed)) throw Error();
        return parsed;
      } catch (_) { fail('drpy_source_response'); }
    }
    function gzApi(path, payload, overrideToken) {
      var token = overrideToken !== undefined ? overrideToken : str(gzState.token);
      var stamp = String(Math.floor(Date.now() / 1000));
      var encKeys = rsaPkcs1('encrypt', str(cfg.publicKey), utf8ToB64(JSON.stringify({ iv: gzIv, key: gzKey })));
      var encrypted = CryptoJS.AES.encrypt(
        JSON.stringify(payload),
        CryptoJS.enc.Utf8.parse(gzKey),
        { iv: CryptoJS.enc.Utf8.parse(gzIv), mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 }
      ).ciphertext.toString().toUpperCase();
      var sigRaw = 'token_id=,token=' + token + ',phone_type=1,request_key=' + encrypted + ',app_id=1,time=' + stamp + ',keys=' + encKeys + str(cfg.signatureSuffix);
      var fields = {
        token: token, token_id: '', phone_type: '1', time: stamp,
        phone_model: str(cfg.phoneModel), keys: encKeys, request_key: encrypted,
        signature: md5Hex(sigRaw).toUpperCase(), app_id: '1', ad_version: '1'
      };
      var body = Object.keys(fields).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(fields[k]); }).join('&');
      var hdrs = {
        'User-Agent': str(cfg.userAgent), Ver: str(cfg.ver), Version: str(cfg.version),
        'api-ver': str(cfg.version), PackageName: str(cfg.pkg), code: str(cfg.code),
        lang: 'zh_cn', Referer: str(cfg.defaultRef), 'Content-Type': 'application/x-www-form-urlencoded'
      };
      for (var i = 0; i < gzHosts.length; i++) {
        var r = httpReqSoft(gzHosts[i] + path, { method: 'POST', body: body, headers: hdrs, timeout: 10000 });
        if (r && r.code === 200) {
          var doc = parseJsonSafe(r.content);
          if (isObj(doc) && Number(doc.code) === 200) {
            gzHost = gzHosts[i];
            return gzDecode(doc);
          }
        }
      }
      fail('drpy_source_unavailable');
    }
    function gzLogin() {
      if (str(gzState.token)) return;
      var payload = { old_key: gzState.old_key, new_key: gzState.new_key };
      var useSignUp = !gzState.registered;
      if (useSignUp) {
        gzState.registered = true;
        local.set('wexguazi-v1', 'device', gzState);
        payload.phone_type = 1;
        payload.code = '';
      }
      var doc = gzApi('/App/Authentication/Device/' + (useSignUp ? 'signUp' : 'signIn'), payload, '');
      if (!str(doc.token)) fail('drpy_authentication_required');
      gzState.token = str(doc.token);
      local.set('wexguazi-v1', 'device', gzState);
    }
    function gzCard(row, homeMode) {
      if (!isObj(row)) return null;
      var id = str(row.vod_id).trim();
      var name = str(homeMode ? (row.c_name || row.vod_name) : row.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(homeMode ? (row.c_pic || row.vod_pic) : row.vod_pic, gzHost + '/'),
        vod_remarks: str(homeMode ? (row.new_continue || row.vod_scroe) : (row.vod_scroe || row.vod_title)).trim()
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '动漫' },
          { type_id: '4', type_name: '综艺' },
          { type_id: '64', type_name: '短剧' },
          { type_id: '74', type_name: '漫剧' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var doc = gzApi('/App/IndexList/index', { pid: '1' });
      var groups = Array.isArray(doc.list) ? doc.list : [];
      var out = [];
      for (var i = 0; i < groups.length; i++) {
        var g = groups[i];
        var arr = isObj(g) && Array.isArray(g.list) ? g.list : [];
        for (var j = 0; j < arr.length; j++) {
          var c = gzCard(arr[j], true);
          if (c) out.push(c);
        }
      }
      return { list: out };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      gzLogin();
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var subMap = { '1': '5', '2': '12', '3': '30', '4': '22' };
      var sub = subMap[str(tid)] || '0';
      var doc = gzApi('/App/IndexList/indexList', {
        area: str(ext.area || '0'), sub: sub, year: str(ext.year || '0'),
        pageSize: '30', sort: 'd_id', page: String(page), tid: str(tid)
      });
      var list = (Array.isArray(doc.list) ? doc.list : []).map(function (r) { return gzCard(r, false); }).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 30, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      if (Number(pg) > 1) return { page: Number(pg), pagecount: 1, limit: 30, total: 0, list: [] };
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 30, total: 0, list: [] };
      gzLogin();
      var doc = gzApi('/App/Index/findMoreVod', { keywords: kw, order_val: '1' });
      var list = (Array.isArray(doc.list) ? doc.list : []).map(function (r) { return gzCard(r, false); }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: 30, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      gzLogin();
      var infoDoc = gzApi('/App/IndexPlay/playInfo', {
        token_id: '', vod_id: str(vid), mobile_time: String(Math.floor(Date.now() / 1000)), token: str(gzState.token)
      });
      var info = isObj(infoDoc.vodInfo) ? infoDoc.vodInfo : infoDoc;
      var vurlDoc = gzApi('/App/Resource/Vurl/show', { vurl_cloud_id: '2', vod_d_id: str(vid) });
      var rows = Array.isArray(vurlDoc.list) ? vurlDoc.list : [];
      var eps = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        var play = isObj(row && row.play) ? row.play : {};
        var param = '';
        var qs = ['1080', '720', '480'];
        for (var q = 0; q < qs.length; q++) {
          if (isObj(play[qs[q]]) && str(play[qs[q]].param)) { param = str(play[qs[q]].param); break; }
        }
        if (!param) continue;
        var pMap = {};
        var sp = param.split('?').pop().split('&');
        for (var k = 0; k < sp.length; k++) {
          var eq = sp[k].indexOf('=');
          if (eq > 0) pMap[sp[k].slice(0, eq)] = decodeURIComponent(sp[k].slice(eq + 1));
        }
        if (!pMap.vurl_id) continue;
        var title = str(row.title || ('第' + (i + 1) + '集')).replace(/[$#]/g, ' ');
        eps.push(title + '$' + encodeEp({
          domain_type: str(pMap.domain_type || '1'),
          vod_id: str(pMap.vod_d_id || vid),
          type: str(pMap.type || '1'),
          resolution: str(pMap.resolution || '1080'),
          vurl_id: str(pMap.vurl_id)
        }));
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(info.vod_name),
          vod_pic: safePic(info.vod_pic, gzHost + '/'),
          vod_year: str(info.vod_year),
          vod_area: str(info.vod_area),
          vod_remarks: str(info.vod_title),
          vod_actor: str(info.vod_actor),
          vod_director: str(info.vod_director),
          vod_content: stripHtml(info.vod_blurb || info.vod_content || '内详'),
          vod_play_from: eps.length ? '专线播放' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var ep = decodeEp(id);
      if (!ep) fail('drpy_media_unresolved');
      gzLogin();
      var doc = gzApi('/App/Resource/VurlDetail/showOne', ep);
      var u = str(doc.url).trim();
      if (!u) fail('drpy_media_unresolved');
      var resolved = address(u, gzHost + '/').url;
      return { parse: 0, url: resolved, header: { 'User-Agent': str(cfg.playUa), Referer: str(cfg.defaultRef) } };
    };
    return;
  }

  // =========================================================================
  // 3. wexduboku-v1 (WexAiDuBoKu — 独播|秒播)
  // =========================================================================
  if (cfg.adapter === 'wexduboku-v1') {
    var dbHost = str(cfg.defaultHost).replace(/\/+$/, '');
    function dbDecodeId(s) {
      var raw = str(s).trim();
      if (!raw) return '';
      if (/^https?:\/\/|^\//i.test(raw)) return raw;
      var out = '';
      for (var i = 0; i < raw.length; i += 10) {
        out += raw.slice(i, i + 10).split('').reverse().join('');
      }
      try { return b64ToUtf8(out.replace(/\./g, '=')); } catch (_) { return raw; }
    }
    function dbJavaRandom(seedBig) {
      var mask = (1n << 48n) - 1n;
      var state = (BigInt(seedBig) ^ 0x5DEECE66Dn) & mask;
      function next(bits) {
        state = (state * 0x5DEECE66Dn + 0xBn) & mask;
        return Number(state >> BigInt(48 - bits));
      }
      return {
        nextInt: function (bound) {
          if ((bound & -bound) === bound) {
            return Number((BigInt(bound) * BigInt(next(31))) >> 31n);
          }
          var bits, val;
          do {
            bits = next(31);
            val = bits % bound;
          } while (bits - val + (bound - 1) < 0);
          return val;
        }
      };
    }
    function dbRandStr(len, seedBig, alphabet) {
      var rng = dbJavaRandom(seedBig);
      var out = '';
      for (var i = 0; i < len; i++) out += alphabet.charAt(rng.nextInt(alphabet.length));
      return out;
    }
    function dbAuthQs() {
      var nowMs = Date.now();
      var tsSec = BigInt(Math.floor(nowMs / 1000));
      var r = dbJavaRandom(tsSec).nextInt(800000000) + 100000000;
      var a = String(r) + String(900000000 - (r - 100000000));
      var b = String(nowMs);
      var mx = Math.max(a.length, b.length), merged = '';
      for (var i = 0; i < mx; i++) {
        if (i < a.length) merged += a.charAt(i);
        if (i < b.length) merged += b.charAt(i);
      }
      var ssid = utf8ToB64(merged).replace(/=/g, '.');
      var sign = dbRandStr(60, tsSec + tsSec + 60n, str(cfg.alphabetPlain));
      var token = dbRandStr(38, tsSec + tsSec + 38n, str(cfg.alphabetShifted));
      return 'sign=' + encodeURIComponent(sign) + '&token=' + encodeURIComponent(token) + '&ssid=' + encodeURIComponent(ssid);
    }
    function dbGet(pathWithMaybeQuery) {
      var p = str(pathWithMaybeQuery);
      var sep = p.indexOf('?') >= 0 ? '&' : '?';
      var full = /^https?:\/\//i.test(p) ? (p + sep + dbAuthQs()) : (dbHost + (p.charAt(0) === '/' ? '' : '/') + p + sep + dbAuthQs());
      var r = httpReq(full, { headers: { 'User-Agent': str(cfg.userAgent), Referer: str(cfg.apiReferer) } });
      var doc = parseJsonSafe(r.content);
      if (!doc) fail('drpy_source_response');
      return doc;
    }
    function dbCard(it) {
      if (!isObj(it)) return null;
      var id = dbDecodeId(it.DId || it.Id || it.vod_id);
      var name = str(it.Name || it.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(dbDecodeId(it.TnId || it.Pic || it.vod_pic), dbHost + '/'),
        vod_remarks: str(it.Tag || it.Rating || it.Remarks).trim()
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '2', type_name: '连续剧' },
          { type_id: '13', type_name: '陆剧' },
          { type_id: '15', type_name: '日韩剧' },
          { type_id: '20', type_name: '港剧' },
          { type_id: '14', type_name: '台泰剧' },
          { type_id: '1', type_name: '电影' },
          { type_id: '3', type_name: '综艺' },
          { type_id: '4', type_name: '动漫' },
          { type_id: '21', type_name: '短剧' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var doc = dbGet('/home');
      var out = [];
      if (Array.isArray(doc)) {
        for (var i = 0; i < doc.length; i++) {
          var vl = isObj(doc[i]) && Array.isArray(doc[i].VodList) ? doc[i].VodList : [];
          for (var j = 0; j < vl.length; j++) { var c = dbCard(vl[j]); if (c) out.push(c); }
        }
      } else if (isObj(doc) && Array.isArray(doc.VodList)) {
        out = doc.VodList.map(dbCard).filter(Boolean);
      }
      return { list: out };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var cid = str(ext.cateId || tid);
      var path = '/vodshow/' + cid + '-' + str(ext.area) + '-' + str(ext.by) + '-' + str(ext.class) + '-' + str(ext.lang) + '----' + (page > 1 ? String(page) : '') + '---' + str(ext.year);
      var doc = dbGet(path);
      var arr = isObj(doc) && Array.isArray(doc.VodList) ? doc.VodList : (Array.isArray(doc) ? doc : []);
      var list = arr.map(dbCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var doc = dbGet('/vodsearch?wd=' + encodeURIComponent(kw));
      var arr = isObj(doc) && Array.isArray(doc.VodList) ? doc.VodList : (Array.isArray(doc) ? doc : []);
      var list = arr.map(dbCard).filter(Boolean);
      return { page: 1, pagecount: 1, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var doc = dbGet(str(vid));
      var pl = Array.isArray(doc.Playlist) ? doc.Playlist : [];
      var eps = [];
      for (var i = 0; i < pl.length; i++) {
        var row = pl[i];
        var epId = dbDecodeId(row && row.VId);
        if (!epId) continue;
        eps.push(str(row.EpisodeName || ('第' + (i + 1) + '集')).replace(/[$#]/g, ' ') + '$' + epId);
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(doc.Name),
          vod_pic: safePic(dbDecodeId(doc.TnId), dbHost + '/'),
          vod_year: str(doc.ReleaseYear),
          vod_area: str(doc.Region),
          vod_actor: Array.isArray(doc.Actor) ? doc.Actor.join(',') : str(doc.Actor),
          vod_director: Array.isArray(doc.Director) ? doc.Director.join(',') : str(doc.Director),
          vod_content: stripHtml(doc.Description),
          vod_play_from: eps.length ? '独播专线' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var doc = dbGet(str(id));
      var mediaUrl = dbDecodeId(doc.HId || doc.Url || doc.url);
      if (!mediaUrl) fail('drpy_media_unresolved');
      return {
        parse: 0,
        url: address(mediaUrl, dbHost + '/').url,
        header: { 'User-Agent': str(cfg.userAgent), Origin: str(cfg.playOrigin), Referer: str(cfg.playReferer) }
      };
    };
    return;
  }

  // =========================================================================
  // 4. wexwencai-v1 (WexAiWenCai — 文才|秒播)
  // =========================================================================
  if (cfg.adapter === 'wexwencai-v1') {
    var wcHost = pickSiteHosts('', [cfg.defaultHost])[0];
    var wcDeviceId = randomUuid();
    function wcGet(path, params) {
      var p = isObj(params) ? params : {};
      var keys = Object.keys(p).filter(function (k) { return p[k] !== undefined && p[k] !== null && str(p[k]) !== ''; }).sort();
      var rawParts = [], encParts = [];
      for (var i = 0; i < keys.length; i++) {
        var k = keys[i], v = str(p[k]);
        rawParts.push(k + '=' + v);
        encParts.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
      }
      var t = String(Date.now());
      var signRaw = (rawParts.length ? (rawParts.join('&') + '&') : '') + str(cfg.signKeyPrefix) + t;
      var sign = sha1Hex(md5Hex(signRaw));
      var url = wcHost + path + (encParts.length ? ('?' + encParts.join('&')) : '');
      var r = httpReq(url, {
        headers: {
          Accept: 'application/json, text/plain, */*',
          'User-Agent': str(cfg.userAgent),
          'client-type': '1',
          deviceId: wcDeviceId,
          t: t,
          sign: sign,
          Referer: str(cfg.referer || (wcHost + '/'))
        }
      });
      var doc = parseJsonSafe(r.content);
      if (!isObj(doc)) fail('drpy_source_response');
      return doc.data !== undefined ? doc.data : doc;
    }
    function wcCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vodId || it.id).trim();
      var name = str(it.vodName || it.title).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vodPic || it.pic, wcHost + '/'),
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
      var d = wcGet('/api/mw-movie/anonymous/home/hotSearch', {});
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      return { list: arr.map(wcCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var d = wcGet('/api/mw-movie/anonymous/video/list', {
        area: str(ext.area), pageNum: String(page), type1: str(tid), year: str(ext.year)
      });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(wcCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 15, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 8, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = wcGet('/api/mw-movie/anonymous/video/searchByWord', { keyword: kw, pageNum: String(page), pageSize: '8' });
      var arr = isObj(d) && isObj(d.result) && Array.isArray(d.result.list) ? d.result.list :
                (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      var list = arr.map(wcCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 8 ? page + 1 : page, limit: 8, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = wcGet('/api/mw-movie/anonymous/video/detail', { id: str(vid) });
      var epsList = Array.isArray(d.episodeList) ? d.episodeList : [];
      var eps = [];
      for (var i = 0; i < epsList.length; i++) {
        var ep = epsList[i];
        var nid = str(ep && (ep.nid !== undefined ? ep.nid : ep.id)).trim();
        if (!nid) continue;
        eps.push(str(ep.name || ('第' + (i + 1) + '集')).replace(/[$#]/g, ' ') + '$' + str(vid) + '|||' + nid);
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.vodName),
          vod_pic: safePic(d.vodPic, wcHost + '/'),
          vod_remarks: str(d.vodVersion || d.vodRemarks),
          vod_year: str(d.vodPubdate || d.vodYear),
          vod_area: str(d.vodArea),
          vod_actor: str(d.vodActor),
          vod_director: str(d.vodDirector),
          vod_content: stripHtml(d.vodContent || d.vodBlurb),
          vod_play_from: eps.length ? '文才专线' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var sp = str(id).split('|||');
      if (sp.length < 2) fail('drpy_media_unresolved');
      var d = wcGet('/api/mw-movie/anonymous/v2/video/episode/url', { id: sp[0], nid: sp[1] });
      var list = isObj(d) && Array.isArray(d.list) ? d.list : [];
      var u = list.length && isObj(list[0]) ? str(list[0].url) : str(d.url);
      if (!u) fail('drpy_media_unresolved');
      return {
        parse: 0,
        url: address(u, wcHost + '/').url,
        header: { 'User-Agent': str(cfg.userAgent), Referer: str(cfg.referer || (wcHost + '/')) }
      };
    };
    return;
  }

  // =========================================================================
  // 5. wexfengye-v1 (WexFengYe4K — 小枫|秒播)
  // =========================================================================
  if (cfg.adapter === 'wexfengye-v1') {
    var fyHosts = pickSiteHosts('', [cfg.defaultHost, cfg.host0, cfg.host1]);
    var fyHost = fyHosts[0];
    var fyHeaders = { 'User-Agent': str(cfg.userAgent), Referer: fyHost + '/' };
    function fyGet(path) {
      for (var i = 0; i < fyHosts.length; i++) {
        var r = httpReqSoft(fyHosts[i] + path, { headers: { 'User-Agent': str(cfg.userAgent), Referer: fyHosts[i] + '/' }, timeout: 9000 });
        if (r && r.code >= 200 && r.code < 400 && str(r.content)) {
          fyHost = fyHosts[i];
          return r.content;
        }
      }
      fail('drpy_source_unavailable');
    }
    function fyParseHtmlCards(html) {
      var out = [], seen = {};
      var re = /<a[^>]+href=["'](\/detail\/(\d+)\.html)["'][^>]*>([\s\S]*?)<\/a>/gi, m;
      while ((m = re.exec(html)) !== null) {
        var id = m[2];
        if (seen[id]) continue;
        var inner = m[3];
        var title = (/title=["']([^"']+)["']/i.exec(m[0]) || /alt=["']([^"']+)["']/i.exec(inner) || [])[1] || stripHtml(inner);
        title = stripHtml(title);
        if (!title) continue;
        seen[id] = true;
        var pic = (/(?:data-original|data-src|src)=["']([^"']+)["']/i.exec(inner) || [])[1] || '';
        out.push({ vod_id: id, vod_name: title, vod_pic: safePic(pic, fyHost + '/'), vod_remarks: '' });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '综艺' },
          { type_id: '4', type_name: '动漫' },
          { type_id: '5', type_name: '短剧' },
          { type_id: 'qq', type_name: '腾讯SVIP' },
          { type_id: 'youku', type_name: '优酷SVIP' },
          { type_id: 'bli', type_name: 'B站SVIP' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      return { list: fyParseHtmlCards(fyGet('/')) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var list = [];
      if (/^\d+$/.test(str(tid))) {
        var raw = fyGet('/index.php/ajax/data?mid=1&tid=' + encodeURIComponent(str(tid)) + '&page=' + page + '&limit=24');
        var doc = parseJsonSafe(raw);
        if (isObj(doc) && Array.isArray(doc.list)) {
          list = doc.list.map(function (it) {
            if (!isObj(it) || !it.vod_id || !it.vod_name) return null;
            return {
              vod_id: str(it.vod_id),
              vod_name: str(it.vod_name),
              vod_pic: safePic(it.vod_pic, fyHost + '/'),
              vod_remarks: str(it.vod_remarks)
            };
          }).filter(Boolean);
        }
        if (!list.length) list = fyParseHtmlCards(fyGet('/type/' + str(tid) + '-' + page + '.html'));
      } else {
        list = fyParseHtmlCards(fyGet('/label/' + encodeURIComponent(str(tid)) + '/page/' + page + '.html'));
      }
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var raw = fyGet('/index.php/ajax/suggest?mid=1&wd=' + encodeURIComponent(kw) + '&limit=30');
      var doc = parseJsonSafe(raw);
      var list = [];
      if (isObj(doc) && Array.isArray(doc.list)) {
        list = doc.list.map(function (it) {
          if (!isObj(it) || !it.id || !it.name) return null;
          return { vod_id: str(it.id), vod_name: str(it.name), vod_pic: safePic(it.pic, fyHost + '/'), vod_remarks: '' };
        }).filter(Boolean);
      }
      return { page: 1, pagecount: 1, limit: 30, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var idNum = str(vid).replace(/\D+/g, '') || str(vid);
      var html = fyGet('/detail/' + idNum + '.html');
      var title = stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text'));
      var pic = safePic(pdfh(html, '.lazyload&&data-original') || pdfh(html, 'img&&data-src') || pdfh(html, 'img&&src'), fyHost + '/');
      var tabNames = pdfa(html, '.module-tab-item, .nav-tabs li a').map(function (t) { return stripHtml(t); }).filter(Boolean);
      var groups = {};
      var order = [];
      var playRe = /<a[^>]+href=["'](\/play\/(\d+)-(\d+)-(\d+)\.html)["'][^>]*>([\s\S]*?)<\/a>/gi, pm;
      while ((pm = playRe.exec(html)) !== null) {
        var sid = pm[3];
        if (!groups[sid]) { groups[sid] = []; order.push(sid); }
        var epTitle = stripHtml(pm[5]) || ('第' + pm[4] + '集');
        groups[sid].push(epTitle.replace(/[$#]/g, ' ') + '$' + pm[1]);
      }
      var froms = [], urls = [];
      for (var i = 0; i < order.length; i++) {
        var sKey = order[i];
        froms.push(tabNames[i] || ('线路' + (i + 1)));
        urls.push(groups[sKey].join('#'));
      }
      return {
        list: [{
          vod_id: idNum,
          vod_name: title || idNum,
          vod_pic: pic,
          vod_content: stripHtml(pdfh(html, '.module-info-introduction-content&&Text') || pdfh(html, '.sketch&&Text')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var html = fyGet(str(id));
      var m = /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</i.exec(html);
      if (!m) fail('drpy_media_unresolved');
      var pj = parseJsonSafe(m[1]);
      if (!isObj(pj) || !str(pj.url)) fail('drpy_media_unresolved');
      var u = str(pj.url).trim();
      if (Number(pj.encrypt) === 1) u = unescape(u);
      else if (Number(pj.encrypt) === 2) u = unescape(b64ToUtf8(u));
      if (isDirectMedia(u)) return { parse: 0, url: address(u, fyHost + '/').url, header: fyHeaders };
      var from = str(pj.from);
      var pBase = /^JD/i.test(from) ? str(cfg.playerJdBase) : (/^co/i.test(from) ? str(cfg.playerCoBase) : '');
      if (pBase) {
        var pr = httpReqSoft(pBase + '?url=' + encodeURIComponent(u), { headers: { 'User-Agent': str(cfg.userAgent), Referer: fyHost + '/' }, timeout: 9000 });
        if (pr && str(pr.content)) {
          var directM = /["'](https?:\/\/[^"'\s]+\.(?:m3u8|mp4)[^"'\s]*)["']/i.exec(pr.content);
          if (directM) return { parse: 0, url: address(directM[1]).url, header: { 'User-Agent': str(cfg.userAgent), Referer: pBase } };
        }
      }
      if (/^https?:\/\//i.test(u)) return { parse: 0, url: address(u).url, header: fyHeaders };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 6. wexjianpian-v1 (WexAiJianPian — 贱片|秒播)
  // =========================================================================
  if (cfg.adapter === 'wexjianpian-v1') {
    var jpSaved = local.get('wexjianpian-v1', 'host');
    var jpHost = isObj(jpSaved) && Number(jpSaved.exp) > Date.now() && str(jpSaved.url) ? str(jpSaved.url) : '';
    var jpCandidates = [];
    function jpPushCand(u) {
      var v = str(u).trim().replace(/\/+$/, '');
      if (/^https?:\/\/[^/?#@]+$/i.test(v) && jpCandidates.indexOf(v) < 0) jpCandidates.push(v);
    }
    if (jpHost) jpPushCand(jpHost);
    if (!jpHost) {
      var dnsRes = httpReqSoft(str(cfg.alidnsUrl), { headers: { Accept: 'application/json' }, timeout: 5000 });
      if (dnsRes && dnsRes.code === 200) {
        var dnsJson = parseJsonSafe(dnsRes.content);
        var answers = isObj(dnsJson) && Array.isArray(dnsJson.Answer) ? dnsJson.Answer : [];
        for (var di = 0; di < answers.length; di++) {
          var parts = str(answers[di] && answers[di].data).replace(/"/g, '').split(',');
          for (var pi = 0; pi < parts.length; pi++) {
            var txt = str(parts[pi]).trim();
            if (txt && /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(txt)) {
              jpPushCand(str(cfg.hostPrefix) + txt);
            }
          }
        }
      }
    }
    jpPushCand(str(cfg.defaultHost));
    if (!jpHost) jpHost = jpCandidates[0] || str(cfg.defaultHost).replace(/\/+$/, '');
    function jpHeadersFor(host) {
      return { 'User-Agent': str(cfg.userAgent), Referer: host, Accept: 'application/json,*/*' };
    }
    function jpGet(path) {
      var order = [jpHost].concat(jpCandidates.filter(function (c) { return c && c !== jpHost; }));
      for (var ci = 0; ci < order.length; ci++) {
        var h = order[ci];
        if (!h) continue;
        var r = httpReqSoft(h + path, { headers: jpHeadersFor(h), timeout: 6000 });
        if (r && r.code >= 200 && r.code < 300) {
          var doc = parseJsonSafe(r.content);
          if (isObj(doc)) {
            if (jpHost !== h) {
              jpHost = h;
              local.set('wexjianpian-v1', 'host', { url: jpHost, exp: Date.now() + 30 * 60 * 1000 });
            }
            return doc.data !== undefined ? doc.data : doc;
          }
        }
      }
      fail('drpy_source_unavailable');
    }
    function jpCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.id || it.vod_id).trim();
      var name = str(it.title || it.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.path || it.thumbnail || it.pic, jpHost + '/'),
        vod_remarks: str(it.mask || it.playlist && it.playlist.title || it.score).trim()
      };
    }
    __drpy.home = function () {
      return {
        class: [
          { type_id: '1', type_name: '电影' },
          { type_id: '2', type_name: '电视剧' },
          { type_id: '3', type_name: '动漫' },
          { type_id: '4', type_name: '综艺' },
          { type_id: '50', type_name: '纪录片' },
          { type_id: '99', type_name: 'Netflix' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var d = jpGet('/api/slide/list?pos_id=88');
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      return { list: arr.map(jpCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var t = str(tid);
      var path = (t === '50' || t === '99' || t === '111')
        ? ('/api/dyTag/list?category_id=' + encodeURIComponent(t) + '&page=' + page)
        : ('/api/crumb/list?fcate_pid=' + encodeURIComponent(t) + '&area=' + encodeURIComponent(str(ext.area || '0')) + '&year=' + encodeURIComponent(str(ext.year || '0')) + '&type=0&sort=' + encodeURIComponent(str(ext.by || 'updata')) + '&page=' + page + '&category_id=');
      var d = jpGet(path);
      var arr = [];
      if (Array.isArray(d)) {
        for (var i = 0; i < d.length; i++) {
          if (isObj(d[i]) && Array.isArray(d[i].dataList)) arr = arr.concat(d[i].dataList);
          else arr.push(d[i]);
        }
      } else if (isObj(d) && Array.isArray(d.list)) {
        arr = d.list;
      }
      var list = arr.map(jpCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 15 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = jpGet('/api/v2/search/videoV2?key=' + encodeURIComponent(kw) + '&category_id=88&page=' + page + '&pageSize=20');
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.data) ? d.data : []);
      var list = arr.map(jpCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = jpGet('/api/video/detailv2?id=' + encodeURIComponent(str(vid)));
      var sources = Array.isArray(d.source_list_source) ? d.source_list_source : [];
      var froms = [], urls = [];
      for (var i = 0; i < sources.length; i++) {
        var src = sources[i];
        var sl = isObj(src) && Array.isArray(src.source_list) ? src.source_list : [];
        var eps = [];
        for (var j = 0; j < sl.length; j++) {
          var ep = sl[j];
          var u = str(ep && ep.url).trim();
          if (!u) continue;
          eps.push(str(ep.source_name || ('第' + (j + 1) + '集')).replace(/[$#]/g, ' ') + '$' + u);
        }
        if (eps.length) {
          froms.push(str(src.name || ('线路' + (i + 1))).replace(/\$\$\$/g, ' '));
          urls.push(eps.join('#'));
        }
      }
      var joinNames = function (arr) {
        if (!Array.isArray(arr)) return str(arr);
        return arr.map(function (x) { return isObj(x) ? str(x.name) : str(x); }).filter(Boolean).join(',');
      };
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.title),
          vod_pic: safePic(d.thumbnail || d.path, jpHost + '/'),
          vod_remarks: str(d.mask),
          vod_year: isObj(d.year) ? str(d.year.title) : str(d.year),
          vod_area: isObj(d.area) ? str(d.area.title) : str(d.area),
          vod_actor: joinNames(d.actors),
          vod_director: joinNames(d.directors),
          vod_content: stripHtml(d.description),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      return { parse: 0, url: address(str(id), jpHost + '/').url, header: { 'User-Agent': str(cfg.userAgent) } };
    };
    return;
  }

  // =========================================================================
  // 7. wexjuxiafan-v1 (WexAiJuXiaFan)
  // =========================================================================
  if (cfg.adapter === 'wexjuxiafan-v1') {
    var jxHosts = pickSiteHosts('', [cfg.defaultHost, cfg.host1, cfg.host2, cfg.host3, cfg.host4, cfg.host5, cfg.host6, cfg.host7]);
    var jxHost = jxHosts[0];
    function jxSign(params) {
      var p = Object.assign({}, params, { timestamp: String(Math.floor(Date.now() / 1000)) });
      var keys = Object.keys(p).filter(function (k) { return p[k] !== undefined && p[k] !== null && str(p[k]) !== ''; }).sort();
      var raw = keys.map(function (k) { return k + '=' + str(p[k]); }).join('&');
      p.datasign = aesEcbEncryptB64(raw, str(cfg.aesKey));
      return p;
    }
    function jxDecodeBody(content) {
      var j = parseJsonSafe(content);
      if (isObj(j)) {
        if (typeof j.data === 'string' && j.data.length > 16 && j.data.indexOf('{') !== 0 && j.data.indexOf('[') !== 0) {
          try {
            var dec = parseJsonSafe(aesEcbDecryptText(j.data, str(cfg.aesKey)));
            if (dec !== null) return dec;
          } catch (_) {}
        }
        return j.data !== undefined ? j.data : j;
      }
      try {
        var plain = parseJsonSafe(aesEcbDecryptText(content, str(cfg.aesKey)));
        if (isObj(plain)) return plain.data !== undefined ? plain.data : plain;
      } catch (_) {}
      return null;
    }
    function jxPost(path, params, asForm) {
      var signed = jxSign(params || {});
      var body = asForm
        ? Object.keys(signed).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(str(signed[k])); }).join('&')
        : JSON.stringify(signed);
      var cType = asForm ? 'application/x-www-form-urlencoded' : 'application/json; charset=utf-8';
      for (var i = 0; i < jxHosts.length; i++) {
        var r = httpReqSoft(jxHosts[i] + path, {
          method: 'POST', body: body,
          headers: { 'User-Agent': str(cfg.userAgent), 'Content-Type': cType },
          timeout: 8000
        });
        if (r && r.code >= 200 && r.code < 300) {
          var dec = jxDecodeBody(r.content);
          if (dec !== null) { jxHost = jxHosts[i]; return dec; }
        }
      }
      fail('drpy_source_unavailable');
    }
    function jxCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vodId || it.id || it.vod_id).trim();
      var name = str(it.vodName || it.name || it.vod_name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vodPic || it.pic || it.vod_pic, jxHost + '/'),
        vod_remarks: str(it.vodRemarks || it.remarks || it.vod_remarks).trim()
      };
    }
    __drpy.home = function () {
      var d = jxPost('/api/v1/video/classifies', {}, false);
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      var classes = [];
      for (var i = 0; i < arr.length; i++) {
        var tid = str(arr[i] && (arr[i].typeId || arr[i].id || arr[i].type_id)).trim();
        var tname = str(arr[i] && (arr[i].typeName || arr[i].name || arr[i].type_name)).trim();
        if (!tid || !tname || tid === '22023') continue;
        classes.push({ type_id: tid, type_name: tname });
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      var d = jxPost('/api/v1/video/index', { pageNum: 1, typeId: 22016 }, false);
      var arr = isObj(d) && Array.isArray(d.records) ? d.records : (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      return { list: arr.map(jxCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var d = jxPost('/api/v1/video/index', {
        pageNum: page, typeId: Number(tid) || tid,
        area: str(ext.area), class: str(ext.class), year: str(ext.year)
      }, false);
      var arr = isObj(d) && Array.isArray(d.records) ? d.records : (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      var list = arr.map(jxCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = jxPost('/api/v1/video/search', { keyword: kw, pageNum: page, typeId: 0 }, false);
      var arr = isObj(d) && Array.isArray(d.records) ? d.records : (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      var list = arr.map(jxCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = jxPost('/api/v1/video/videoDetails', { id: str(vid) }, true);
      var sources = Array.isArray(d.playerSource) ? d.playerSource : (Array.isArray(d.vodPlayList) ? d.vodPlayList : []);
      var froms = [], urls = [];
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i];
        var fromCode = str(s && (s.from || s.playerCode || s.code || ('线路' + (i + 1))));
        var epArr = Array.isArray(s && s.episodes) ? s.episodes : (Array.isArray(s && s.urls) ? s.urls : []);
        var eps = [];
        for (var j = 0; j < epArr.length; j++) {
          var ep = epArr[j];
          var u = str(ep && (ep.url || ep.code || ep.playUrl)).trim();
          if (!u) continue;
          eps.push(str(ep.name || ep.title || ('第' + (j + 1) + '集')).replace(/[$#]/g, ' ') + '$' + encodeEp({ f: fromCode, u: u }));
        }
        if (eps.length) {
          froms.push(str(s.name || fromCode).replace(/\$\$\$/g, ' '));
          urls.push(eps.join('#'));
        }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.vodName || d.name),
          vod_pic: safePic(d.vodPic || d.pic, jxHost + '/'),
          vod_remarks: str(d.vodRemarks || d.remarks),
          vod_year: str(d.vodYear || d.year),
          vod_area: str(d.vodArea || d.area),
          vod_actor: str(d.vodActor || d.actor),
          vod_director: str(d.vodDirector || d.director),
          vod_content: stripHtml(d.vodContent || d.vodBlurb || d.content),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var ep = decodeEp(id) || { f: str(flag), u: str(id) };
      if (isDirectMedia(ep.u)) return { parse: 0, url: address(ep.u, jxHost + '/').url, header: { 'User-Agent': str(cfg.userAgent) } };
      var d = jxPost('/api/v1/player/analysisUrl', { from: str(ep.f), code: str(ep.u) }, true);
      var u = isObj(d) ? str(d.url) : str(d);
      if (!u) fail('drpy_media_unresolved');
      return { parse: 0, url: address(u, jxHost + '/').url, header: { 'User-Agent': str(cfg.userAgent) } };
    };
    return;
  }

  // =========================================================================
  // 8. wexrebo-v1 (WexAiReBo)
  // =========================================================================
  if (cfg.adapter === 'wexrebo-v1') {
    var rbBoundary = (/boundary=([^\s;]+)/i.exec(str(cfg.multipartType)) || [])[1] || '----MarcoWexBoundary';
    function rbPost(url, fields) {
      var ts = String(Math.floor(Date.now() / 1000));
      var all = Object.assign({}, fields || {}, { timestamp: ts, sign: md5Hex(str(cfg.signSecret) + ts) });
      var lines = [];
      var keys = Object.keys(all);
      for (var i = 0; i < keys.length; i++) {
        lines.push('--' + rbBoundary);
        lines.push('Content-Disposition: form-data; name="' + keys[i] + '"');
        lines.push('');
        lines.push(str(all[keys[i]]));
      }
      lines.push('--' + rbBoundary + '--');
      lines.push('');
      var r = httpReq(url, {
        method: 'POST',
        headers: { 'User-Agent': str(cfg.apiUa), 'Content-Type': 'multipart/form-data; boundary=' + rbBoundary },
        body: lines.join('\r\n')
      });
      var doc = parseJsonSafe(r.content);
      if (!isObj(doc)) fail('drpy_source_response');
      return doc.data !== undefined ? doc.data : doc;
    }
    function rbCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vod_id || it.id).trim();
      var name = str(it.vod_name || it.name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vod_pic || it.vod_pic_thumb, cfg.origin + '/'),
        vod_remarks: str(it.vod_remarks).trim()
      };
    }
    __drpy.home = function () {
      var d = rbPost(str(cfg.topTypeUrl), {});
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var classes = [];
      for (var i = 0; i < arr.length; i++) {
        var tid = str(arr[i] && arr[i].type_id).trim();
        var tname = str(arr[i] && arr[i].type_name).trim();
        if (tid && tname) classes.push({ type_id: tid, type_name: tname });
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      var d = rbPost(str(cfg.typeSearchUrl), { type_id: '1', page: '1' });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      return { list: arr.map(rbCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var d = rbPost(str(cfg.typeSearchUrl), {
        type_id: str(tid), page: String(page),
        class: str(ext.class), area: str(ext.area), year: str(ext.year), lang: str(ext.lang)
      });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(rbCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = rbPost(str(cfg.searchUrl), { keyword: kw, page: String(page), limit: '20' });
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(rbCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = rbPost(str(cfg.detailUrl), { vod_id: str(vid) });
      var plist = Array.isArray(d.vod_play_list) ? d.vod_play_list : [];
      var froms = [], urls = [];
      for (var i = 0; i < plist.length; i++) {
        var p = plist[i];
        var pUrls = Array.isArray(p && p.parse_urls) ? p.parse_urls : [];
        var uArr = Array.isArray(p && p.urls) ? p.urls : [];
        var eps = [];
        for (var j = 0; j < uArr.length; j++) {
          var u = str(uArr[j] && uArr[j].url).trim();
          if (!u) continue;
          eps.push(str(uArr[j].name || ('第' + (j + 1) + '集')).replace(/[$#]/g, ' ') + '$' + encodeEp({ u: u, p: pUrls }));
        }
        if (eps.length) {
          froms.push(str(p.title || p.name || ('线路' + (i + 1))).replace(/\$\$\$/g, ' '));
          urls.push(eps.join('#'));
        }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.vod_name),
          vod_pic: safePic(d.vod_pic, cfg.origin + '/'),
          vod_remarks: str(d.vod_remarks),
          vod_year: str(d.vod_year),
          vod_area: str(d.vod_area),
          vod_actor: str(d.vod_actor),
          vod_director: str(d.vod_director),
          vod_content: stripHtml(d.vod_content || d.vod_blurb),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var ep = decodeEp(id) || { u: str(id), p: [] };
      var playHdr = { 'User-Agent': str(cfg.playUa) };
      if (isDirectMedia(ep.u)) return { parse: 0, url: address(ep.u).url, header: playHdr };
      var parsers = Array.isArray(ep.p) ? ep.p : [];
      for (var i = 0; i < parsers.length; i++) {
        var pu = str(parsers[i]).trim();
        if (!/^https?:\/\//i.test(pu)) continue;
        var r = httpReqSoft(pu + encodeURIComponent(ep.u), { headers: playHdr, timeout: 8000 });
        if (r && r.code >= 200 && r.code < 300) {
          var j = parseJsonSafe(r.content);
          var mu = isObj(j) ? str(j.url || (isObj(j.data) && j.data.url)) : '';
          if (/^https?:\/\//i.test(mu)) return { parse: 0, url: address(mu).url, header: playHdr };
        }
      }
      if (/^https?:\/\//i.test(ep.u)) return { parse: 0, url: address(ep.u).url, header: playHdr };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 9. wexbobo-v1 (WexAiBoBo)
  // =========================================================================
  if (cfg.adapter === 'wexbobo-v1') {
    var bbHost = str(cfg.defaultHost).replace(/\/+$/, '');
    var bbHeaders = { 'User-Agent': str(cfg.userAgent), Referer: bbHost + '/' };
    function bbParseCards(html, sel) {
      var rows = pdfa(html, sel), out = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        var href = pdfh(row, 'a&&href');
        var name = stripHtml(pdfh(row, 'a&&title') || pdfh(row, 'img&&alt') || pdfh(row, 'span.sTit&&Text'));
        if (!href || !name) continue;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(row, 'img&&data-src') || pdfh(row, 'img&&src'), bbHost + '/'),
          vod_remarks: stripHtml(pdfh(row, 'span.sBottom&&Text'))
        });
      }
      return out;
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
      var html = httpReq(bbHost + '/', { headers: bbHeaders }).content;
      return { list: bbParseCards(html, 'ul.resize_list > li') };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var cid = str(ext.cateId || tid);
      var url = bbHost + '/index.php?m=vod-list-id-' + cid + '-pg-' + page + '-order--by-' + str(ext.by || 'time') + '-class-0-year-' + str(ext.year) + '-letter--area-' + str(ext.area) + '-lang-.html';
      var html = httpReq(url, { headers: bbHeaders }).content;
      var list = bbParseCards(html, 'section.mod-bd.clearfix ul > li');
      if (!list.length) list = bbParseCards(html, 'ul.resize_list > li');
      return { page: page, pagecount: list.length >= 15 ? page + 1 : page, limit: 30, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var url = bbHost + '/index.php?m=vod-search-pg-' + page + '-wd-' + encodeURIComponent(kw) + '.html';
      var html = httpReq(url, { headers: bbHeaders }).content;
      var list = bbParseCards(html, '.ulPicTxt.clearfix > li');
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), bbHost + '/').url, { headers: bbHeaders }).content;
      var fromM = /mac_from\s*=\s*['"]([^'"]*)['"]/i.exec(html);
      var urlM = /mac_url\s*=\s*(?:unescape\()?['"]([^'"]*)['"]/i.exec(html);
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h1&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.pic img&&src') || pdfh(html, 'img&&src'), bbHost + '/'),
          vod_content: stripHtml(pdfh(html, '.txtDesc&&Text')),
          vod_play_from: fromM ? str(fromM[1]) : '默认线路',
          vod_play_url: urlM ? unescape(str(urlM[1])) : ''
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var raw = str(id).trim();
      if (isDirectMedia(raw)) return { parse: 0, url: address(raw, bbHost + '/').url, header: bbHeaders };
      var target = '';
      if (raw.indexOf('dJj') === 0) {
        var rc = loadRemoteWexConfig();
        if (rc.mySiteUrl) target = rc.mySiteUrl.replace(/\/+$/, '') + str(cfg.boboParsePath) + '?url=' + encodeURIComponent(raw);
      } else if (raw.indexOf('bFWBFI09Z7X3J1pHYeWlwlvocW') === 0) {
        target = str(cfg.parseUrlB) + encodeURIComponent(raw);
      } else if (raw.indexOf('aFHBRI09') === 0) {
        target = str(cfg.parseUrlA) + encodeURIComponent(raw);
      } else {
        target = str(cfg.parseUrlA) + encodeURIComponent(raw);
      }
      if (target) {
        var r = httpReq(target, { headers: bbHeaders });
        var j = parseJsonSafe(r.content);
        var ju = isObj(j) ? str(j.url || (isObj(j.data) && j.data.url)) : '';
        if (!ju) {
          var m = /(?:url|video\s*:\s*\{\s*url)\s*[=:]\s*['"](https?:\/\/[^'"]+)['"]/i.exec(r.content);
          if (m) ju = m[1];
        }
        if (/^https?:\/\//i.test(ju)) return { parse: 0, url: address(ju).url, header: bbHeaders };
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  // =========================================================================
  // 10. wexikanbot-v1 (WexAiIkanBot)
  // =========================================================================
  if (cfg.adapter === 'wexikanbot-v1') {
    var ikHost = pickSiteHosts('', [cfg.defaultHost])[0];
    var ikHeaders = { 'User-Agent': str(cfg.userAgent), Referer: ikHost + '/' };
    function ikCards(html) {
      var items = pdfa(html, '.v-list a.item, .col-xs-4.col-sm-3.col-md-2.item, a.item');
      var out = [], seen = {};
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var href = pdfh(it, 'a&&href') || (/href=["']([^"']+)["']/i.exec(it) || [])[1] || '';
        if (!href || seen[href]) continue;
        var name = stripHtml(pdfh(it, 'p&&Text') || pdfh(it, 'img&&alt'));
        if (!name) continue;
        seen[href] = true;
        out.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(it, 'img&&data-src') || pdfh(it, 'img&&src'), ikHost + '/'),
          vod_remarks: ''
        });
      }
      return out;
    }
    __drpy.home = function () {
      return {
        class: [{ type_id: 'movie', type_name: '电影' }, { type_id: 'tv', type_name: '剧集' }],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      var html = httpReq(ikHost + '/', { headers: ikHeaders }).content;
      return { list: ikCards(html) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var tag = encodeURIComponent(str(ext.class || '热门'));
      var path = page > 1 ? ('/hot/index-' + str(tid) + '-' + tag + '-p-' + page + '.html') : ('/hot/index-' + str(tid) + '-' + tag + '.html');
      var list = ikCards(httpReq(ikHost + path, { headers: ikHeaders }).content);
      return { page: page, pagecount: list.length >= 12 ? page + 1 : page, limit: 24, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var path = '/search?q=' + encodeURIComponent(kw) + (page > 1 ? ('&p=' + page) : '');
      var html = httpReq(ikHost + path, { headers: ikHeaders }).content;
      var rows = pdfa(html, '.media');
      var list = [];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var href = pdfh(r, 'a&&href');
        var name = stripHtml(pdfh(r, '.title-text&&Text') || pdfh(r, 'h5&&Text'));
        if (!href || !name) continue;
        list.push({
          vod_id: href,
          vod_name: name,
          vod_pic: safePic(pdfh(r, 'img&&data-src') || pdfh(r, 'img&&src'), ikHost + '/'),
          vod_remarks: stripHtml(pdfh(r, '.label&&Text'))
        });
      }
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var html = httpReq(address(str(vid), ikHost + '/').url, { headers: ikHeaders }).content;
      var cid = pdfh(html, '#current_id&&value');
      var etk = pdfh(html, '#e_token&&value');
      var mtype = pdfh(html, '#mtype&&value') || '2';
      var tail = cid.slice(-4), tok = '';
      for (var i = 0; i < tail.length; i++) {
        var d = parseInt(tail.charAt(i), 10) || 0;
        var s = d * 3 + 1;
        tok += etk.slice(s, s + 8);
        etk = etk.slice(s + 8);
      }
      var apiRes = httpReq(ikHost + '/api/getResN?videoId=' + encodeURIComponent(cid) + '&mtype=' + encodeURIComponent(mtype) + '&token=' + encodeURIComponent(tok), { headers: ikHeaders });
      var doc = parseJsonSafe(apiRes.content);
      var list = isObj(doc) && isObj(doc.data) && Array.isArray(doc.data.list) ? doc.data.list : [];
      var froms = [], urls = [];
      for (var j = 0; j < list.length; j++) {
        var rd = parseJsonSafe(list[j] && list[j].resData);
        var arr = Array.isArray(rd) ? rd : [];
        for (var k = 0; k < arr.length; k++) {
          var item = arr[k];
          if (isObj(item) && str(item.flag) && str(item.url)) {
            froms.push(str(item.flag).replace(/\$\$\$/g, ' '));
            urls.push(str(item.url).replace(/##/g, '#'));
          }
        }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: stripHtml(pdfh(html, 'h2.title&&Text') || pdfh(html, 'title&&Text')),
          vod_pic: safePic(pdfh(html, '.item-root img&&data-src') || pdfh(html, '.item-root img&&src'), ikHost + '/'),
          vod_year: stripHtml(pdfh(html, '.year&&Text')),
          vod_area: stripHtml(pdfh(html, '.country&&Text')),
          vod_actor: stripHtml(pdfh(html, '.celebrity&&Text')),
          vod_content: stripHtml(pdfh(html, '.summary&&Text')),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      return { parse: 0, url: address(str(id), ikHost + '/').url, header: ikHeaders };
    };
    return;
  }

  // =========================================================================
  // 11. wexyiys-v1 (WexAiYiYs)
  // =========================================================================
  if (cfg.adapter === 'wexyiys-v1') {
    function rsaPublicDecryptSpki(pem, cipherB64) {
      function b64Bytes(s) {
        var clean = str(s).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
        var wa = CryptoJS.enc.Base64.parse(clean);
        var out = new Uint8Array(wa.sigBytes);
        for (var i = 0; i < wa.sigBytes; i++) out[i] = (wa.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 255;
        return out;
      }
      function readDer(buf, pos) {
        var tag = buf[pos++];
        var len = buf[pos++];
        if (len & 0x80) {
          var nBytes = len & 0x7f; len = 0;
          for (var i = 0; i < nBytes; i++) len = (len << 8) | buf[pos++];
        }
        return { tag: tag, start: pos, len: len, end: pos + len };
      }
      function toBig(bytes) {
        var v = 0n;
        for (var i = 0; i < bytes.length; i++) v = (v << 8n) | BigInt(bytes[i]);
        return v;
      }
      function modPow(base, exp, mod) {
        var r = 1n, b = base % mod, e = exp;
        while (e > 0n) {
          if (e & 1n) r = (r * b) % mod;
          e >>= 1n;
          b = (b * b) % mod;
        }
        return r;
      }
      var der = b64Bytes(pem);
      var outer = readDer(der, 0);
      var alg = readDer(der, outer.start);
      var bitStr = readDer(der, alg.end);
      var rsaSeq = readDer(der, bitStr.start + 1);
      var modNode = readDer(der, rsaSeq.start);
      var expNode = readDer(der, modNode.end);
      var n = toBig(der.subarray(modNode.start, modNode.end));
      var e = toBig(der.subarray(expNode.start, expNode.end));
      var cBytes = b64Bytes(cipherB64);
      var m = modPow(toBig(cBytes), e, n);
      var kLen = modNode.len - (der[modNode.start] === 0 ? 1 : 0);
      var em = new Uint8Array(kLen);
      for (var idx = kLen - 1; idx >= 0; idx--) { em[idx] = Number(m & 255n); m >>= 8n; }
      if (em[0] !== 0 || (em[1] !== 1 && em[1] !== 2)) fail('drpy_crypto_invalid');
      var sepIdx = -1;
      for (var s = 2; s < em.length; s++) { if (em[s] === 0) { sepIdx = s; break; } }
      if (sepIdx < 0) fail('drpy_crypto_invalid');
      var payload = em.subarray(sepIdx + 1);
      var waOut = CryptoJS.lib.WordArray.create([], 0);
      var words = [];
      for (var p = 0; p < payload.length; p++) words[p >>> 2] = (words[p >>> 2] || 0) | (payload[p] << (24 - (p % 4) * 8));
      waOut.words = words; waOut.sigBytes = payload.length;
      return CryptoJS.enc.Utf8.stringify(waOut);
    }
    var yiSession = null;
    function yiEnsureToken() {
      if (yiSession) return yiSession;
      var appId = randomChars(16, '0123456789abcdefghijklmnopqrstuvwxyz');
      var boundary = '----YiYsForm' + randomHex(12);
      var ts = String(Math.floor(Date.now() / 1000));
      var body = [
        '--' + boundary, 'Content-Disposition: form-data; name="appID"', '', appId,
        '--' + boundary, 'Content-Disposition: form-data; name="timestamp"', '', ts,
        '--' + boundary + '--', ''
      ].join('\r\n');
      var r = httpReq(str(cfg.genKeyUrl), {
        method: 'POST',
        headers: {
          'User-Agent': str(cfg.apiUa), 'APP-ID': appId, 'X-Auth-Flow': '1',
          'Content-Type': 'multipart/form-data; boundary=' + boundary
        },
        body: body
      });
      var doc = parseJsonSafe(r.content);
      var enc = isObj(doc) ? str(doc.data) : '';
      if (!enc) fail('drpy_authentication_required');
      var plain = rsaPublicDecryptSpki(str(cfg.rsaPublicKeyPem), enc).trim();
      yiSession = { appId: appId, suffix: '&token=' + plain };
      return yiSession;
    }
    function yiGet(baseUrl, pairs) {
      var sess = yiEnsureToken();
      var rawQs = pairs.map(function (kv) { return kv[0] + '=' + kv[1]; }).join('&');
      var encQs = pairs.map(function (kv) { return encodeURIComponent(kv[0]) + '=' + encodeURIComponent(kv[1]); }).join('&');
      var hash = sha256Hex(rawQs + sess.suffix);
      var fullUrl = baseUrl.indexOf('?timestamp=') >= 0
        ? (baseUrl.split('?')[0] + '?' + encQs)
        : (baseUrl + (baseUrl.indexOf('?') >= 0 ? '&' : '?') + encQs);
      var r = httpReq(fullUrl, {
        headers: { 'User-Agent': str(cfg.apiUa), 'APP-ID': sess.appId, 'X-Auth-Flow': '1', 'X-HASH-Data': hash }
      });
      var doc = parseJsonSafe(r.content);
      if (!isObj(doc)) fail('drpy_source_response');
      return doc.data !== undefined ? doc.data : doc;
    }
    function yiCard(it) {
      if (!isObj(it)) return null;
      var id = str(it.vodId || it.vod_id || it.id).trim();
      var name = str(it.vodName || it.vod_name || it.name).trim();
      if (!id || !name) return null;
      return {
        vod_id: id,
        vod_name: name,
        vod_pic: safePic(it.vodPic || it.vod_pic || it.pic, cfg.origin + '/'),
        vod_remarks: str(it.vodRemarks || it.vod_remarks || it.remarks).trim()
      };
    }
    __drpy.home = function () {
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.typeListUrl), [['timestamp', ts]]);
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      var classes = [];
      for (var i = 0; i < arr.length; i++) {
        var tid = str(arr[i] && (arr[i].typeId || arr[i].type_id)).trim();
        var tname = str(arr[i] && (arr[i].typeName || arr[i].type_name)).trim();
        if (tid && tname) classes.push({ type_id: tid, type_name: tname });
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.vodListUrl), [
        ['area', ''], ['by', 'time'], ['class', ''], ['lang', ''],
        ['limit', '30'], ['page', '1'], ['tid', '1'], ['timestamp', ts], ['year', '']
      ]);
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      return { list: arr.map(yiCard).filter(Boolean) };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.vodListUrl), [
        ['area', str(ext.area)], ['by', str(ext.by || 'time')], ['class', str(ext.class)], ['lang', str(ext.lang)],
        ['limit', '45'], ['page', String(page)], ['tid', str(tid)], ['timestamp', ts], ['year', str(ext.year)]
      ]);
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(yiCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 45, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.searchUrlApi), [['key', kw], ['limit', '20'], ['page', String(page)], ['timestamp', ts]]);
      var arr = isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []);
      var list = arr.map(yiCard).filter(Boolean);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.vodInfoUrl), [['tid', ''], ['timestamp', ts], ['vodId', str(vid)]]);
      var plist = Array.isArray(d.vodPlayList || d.playList) ? (d.vodPlayList || d.playList) : [];
      var froms = [], urls = [];
      for (var i = 0; i < plist.length; i++) {
        var pl = plist[i];
        var sc = str(pl && (pl.sourceCode || pl.playerCode || pl.from));
        var uArr = Array.isArray(pl && (pl.urls || pl.episodeList)) ? (pl.urls || pl.episodeList) : [];
        var eps = [];
        for (var j = 0; j < uArr.length; j++) {
          var u = str(uArr[j] && (uArr[j].urlEncode || uArr[j].url)).trim();
          if (!u) continue;
          eps.push(str(uArr[j].name || ('第' + (j + 1) + '集')).replace(/[$#]/g, ' ') + '$' + encodeEp({ s: sc, u: u }));
        }
        if (eps.length) {
          froms.push(str(pl.sourceName || pl.name || sc || ('线路' + (i + 1))).replace(/\$\$\$/g, ' '));
          urls.push(eps.join('#'));
        }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(d.vodName || d.vod_name),
          vod_pic: safePic(d.vodPic || d.vod_pic, cfg.origin + '/'),
          vod_remarks: str(d.vodRemarks || d.vod_remarks),
          vod_year: str(d.vodYear || d.vod_year),
          vod_area: str(d.vodArea || d.vod_area),
          vod_actor: str(d.vodActor || d.vod_actor),
          vod_director: str(d.vodDirector || d.vod_director),
          vod_content: stripHtml(d.vodContent || d.vod_content),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var ep = decodeEp(id) || { s: str(flag), u: str(id) };
      if (isDirectMedia(ep.u)) return { parse: 0, url: address(ep.u).url, header: { 'User-Agent': str(cfg.playUa) } };
      var ts = String(Math.floor(Date.now() / 1000));
      var d = yiGet(str(cfg.playUrlApi), [['sourceCode', str(ep.s)], ['timestamp', ts], ['urlEncode', str(ep.u)]]);
      var mu = isObj(d) ? str(d.url || d.playUrl) : str(d);
      if (!mu) fail('drpy_media_unresolved');
      return { parse: 0, url: address(mu).url, header: { 'User-Agent': str(cfg.playUa) } };
    };
    return;
  }

  // =========================================================================
  // 12. wexhanxiaoquan-v1 (WexAiHanXiaoQuan)
  // =========================================================================
  if (cfg.adapter === 'wexhanxiaoquan-v1') {
    var hxqHost = pickSiteHosts('', [cfg.defaultHost])[0];
    var hxqDev = local.get('wexhanxiaoquan-v1', 'device');
    if (!isObj(hxqDev) || !str(hxqDev.uid)) {
      hxqDev = {
        uid: randomChars(20, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'),
        said: randomHex(16),
        oa: randomHex(16),
        it: Date.now() - 1209600000,
        uuid: randomChars(32, '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ')
      };
      local.set('wexhanxiaoquan-v1', 'device', hxqDev);
    }
    var hxqTokens = {};
    function hxqHeaders() {
      var now = Date.now();
      var md5Uid = md5Hex(hxqDev.uid);
      var signBody = JSON.stringify({
        emu: 0, ou: 0, it: hxqDev.it, iit: hxqDev.it, bs: 0, uid: hxqDev.uid,
        pc: 0, tm: 81, d8m: '0,0,0,0,0,0,0,4', md: 'V2238A', maker: 'vivo', osv: '12',
        br: 95, rpc: 0, scc: 2, plc: 6, toc: 19, tsc: 10, ts: now, pa: 1, crec: 0,
        nw: 2, px: '0', isp: '', ai: hxqDev.said, oa: hxqDev.oa, dpc: 0, dsc: 0,
        qpc: 0, apad: 0, pk: str(cfg.appPkg)
      });
      return {
        app: 'hj', ch: 'vivo', said: hxqDev.said,
        uk: aesCbcEncryptB64(hxqDev.uid, str(cfg.signSaltA), str(cfg.signSaltB)),
        vn: str(cfg.appVer),
        sign: aesCbcEncryptB64(signBody, md5Uid.slice(0, 16), md5Uid.slice(16, 32)),
        'User-Agent': str(cfg.apiUa),
        vc: str(cfg.appVc)
      };
    }
    function hxqAesDecryptClean(cipherB64, keyStr, ivStr) {
      var paddings = [CryptoJS.pad.Pkcs7, CryptoJS.pad.ZeroPadding, CryptoJS.pad.NoPadding];
      for (var i = 0; i < paddings.length; i++) {
        try {
          var dec = CryptoJS.AES.decrypt(str(cipherB64), CryptoJS.enc.Utf8.parse(str(keyStr)), {
            iv: CryptoJS.enc.Utf8.parse(str(ivStr)),
            mode: CryptoJS.mode.CBC,
            padding: paddings[i]
          }).toString(CryptoJS.enc.Utf8);
          var cleaned = str(dec).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]+$/g, '').trim();
          if (cleaned) return cleaned;
        } catch (_) {}
      }
      return '';
    }
    function hxqDecryptEnvelope(doc) {
      if (!isObj(doc)) return null;
      if (typeof doc.data === 'string' && doc.data.length > 20) {
        var h = md5Hex(md5Hex(hxqDev.uid + str(doc.ts)) + str(cfg.aesIvDefault));
        var plain = hxqAesDecryptClean(doc.data, h.slice(0, 16), h.slice(16, 32));
        var parsed = parseJsonSafe(plain);
        if (parsed) return parsed;
        var braceStart = plain.indexOf('{'), braceEnd = plain.lastIndexOf('}');
        if (braceStart >= 0 && braceEnd > braceStart) {
          parsed = parseJsonSafe(plain.slice(braceStart, braceEnd + 1));
          if (parsed) return parsed;
        }
        return null;
      }
      return isObj(doc.data) ? doc.data : doc;
    }
    function hxqGet(path, params) {
      var p = isObj(params) ? params : {};
      var qs = Object.keys(p).filter(function (k) { return str(p[k]) !== ''; }).map(function (k) {
        return encodeURIComponent(k) + '=' + encodeURIComponent(str(p[k]));
      }).join('&');
      var url = hxqHost + path + (qs ? ((path.indexOf('?') >= 0 ? '&' : '?') + qs) : '');
      var r = httpReq(url, { headers: hxqHeaders() });
      var doc = parseJsonSafe(r.content);
      if (!isObj(doc) || Number(doc.rescode) !== 0) fail('drpy_source_response');
      return hxqDecryptEnvelope(doc) || {};
    }
    function hxqRewriteCdn(rawUrl) {
      var u = str(rawUrl).trim();
      if (!u || !/^http:\/\//i.test(u)) return u;
      if (u.indexOf('voldn') < 0 && u.indexOf('hwcpicc') < 0) return u;
      var slash = u.indexOf('/', u.indexOf('://') + 3);
      return slash > 0 ? (str(cfg.picCdnHost).replace(/\/+$/, '') + u.slice(slash)) : u;
    }
    function hxqPic(it) {
      if (!isObj(it)) return '';
      if (isObj(it.image)) return safePic(it.image.url || it.image.thumb, hxqHost + '/');
      if (typeof it.image === 'string' && it.image) return safePic(it.image, hxqHost + '/');
      return safePic(it.poster || it.thumb, hxqHost + '/');
    }
    function hxqCard(it) {
      if (!isObj(it)) return null;
      var sid = str(it.sid).trim();
      var name = str(it.name).trim();
      if (!sid || !name) return null;
      return {
        vod_id: sid,
        vod_name: name,
        vod_pic: hxqPic(it),
        vod_remarks: str(it.conerMemo || it.detailMemo || it.shorthand).trim()
      };
    }
    function hxqCollectCards(node, out, seen) {
      if (!node) return;
      if (Array.isArray(node)) {
        for (var i = 0; i < node.length; i++) hxqCollectCards(node[i], out, seen);
        return;
      }
      if (!isObj(node)) return;
      var card = hxqCard(node);
      if (card) {
        if (!seen[card.vod_id]) { seen[card.vod_id] = 1; out.push(card); }
        return;
      }
      var keys = Object.keys(node);
      for (var k = 0; k < keys.length; k++) {
        if (keys[k] === 'groups' || keys[k] === 'filters' || keys[k] === 'cates') continue;
        hxqCollectCards(node[keys[k]], out, seen);
      }
    }
    __drpy.home = function () {
      var d = hxqGet('/api/series2/arrange/cate', { stype: '1', page: '1' });
      var groups = Array.isArray(d.groups) ? d.groups : [];
      var classes = [];
      for (var i = 0; i < groups.length; i++) {
        var st = str(groups[i] && groups[i].stype).trim();
        var nm = str(groups[i] && groups[i].name).trim();
        if (st && nm) classes.push({ type_id: st, type_name: nm });
      }
      if (!classes.length) {
        classes = [{ type_id: '1', type_name: '韩剧' }, { type_id: '2', type_name: '综艺' }, { type_id: '3', type_name: '电影' }];
      }
      return { class: classes, filters: {} };
    };
    __drpy.homeVod = function () {
      var list = [], seen = {};
      try {
        var rec = hxqGet('/api/index/recommend_v5', { page: '1' });
        hxqCollectCards(rec, list, seen);
      } catch (_) {}
      if (!list.length) {
        var d = hxqGet('/api/series2/arrange/cate', { stype: '1', page: '1' });
        hxqCollectCards(d, list, seen);
      }
      return { list: list };
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var ext = isObj(extend) ? extend : {};
      var params = { stype: str(tid), page: String(page) };
      if (str(ext.cid) && str(ext.cid) !== '-1') params.cid = str(ext.cid);
      if (str(ext.sort)) params.sort = str(ext.sort);
      if (str(ext.year)) params.year = str(ext.year);
      var d = hxqGet('/api/series2/arrange/cate', params);
      var list = [];
      hxqCollectCards(d, list, {});
      var more = Number(d.more) > 0 || list.length >= 20;
      return { page: page, pagecount: more ? page + 1 : page, limit: 30, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var page = Math.max(1, Number(pg) || 1);
      var d = hxqGet('/api/search/s4', { k: kw, srefer: 'search', type: '0', page: String(page) });
      var list = [];
      hxqCollectCards(d, list, {});
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (vid) {
      var d = hxqGet('/api/series2/detail/normal', { sid: str(vid) });
      var s = isObj(d.series) ? d.series : d;
      var items = Array.isArray(d.playItems) ? d.playItems : [];
      var qualities = [['蓝光1080P', '11', '1'], ['高清720P', '10', '1'], ['标清480P', '2', '0']];
      var froms = [], urls = [];
      for (var q = 0; q < qualities.length; q++) {
        var qInfo = qualities[q];
        var eps = [];
        for (var i = 0; i < items.length; i++) {
          var pi = items[i];
          var pid = str(pi && pi.pid).trim();
          if (!pid) continue;
          var epTitle = str(pi.title || ('第' + (pi.serialNo || (i + 1)) + '集')).replace(/[$#]/g, ' ');
          eps.push(epTitle + '$' + [str(vid), pid, '', qInfo[1], qInfo[2]].join('|||'));
        }
        if (eps.length) { froms.push(qInfo[0]); urls.push(eps.join('#')); }
      }
      return {
        list: [{
          vod_id: str(vid),
          vod_name: str(s.name),
          vod_pic: hxqPic(s),
          vod_year: str(s.year),
          vod_area: '韩国',
          vod_actor: str(s.crew),
          vod_content: stripHtml(s.intro || s.shorthand),
          vod_play_from: froms.join('$$$'),
          vod_play_url: urls.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var sp = str(id).split('|||');
      var pid = str(sp[1]).trim();
      var scid = str(sp[2]).trim();
      var sq = str(sp[3] || '10').trim();
      var re = str(sp[4] || '0').trim();
      if (!pid) fail('drpy_media_unresolved');
      if (!scid) {
        var epDetail = hxqGet('/api/series2/episode/detail', { pid: pid });
        var sources = isObj(epDetail.playItem) && Array.isArray(epDetail.playItem.sources) ? epDetail.playItem.sources : [];
        scid = sources.length && isObj(sources[0]) ? str(sources[0].scid).trim() : '';
      }
      if (!scid) fail('drpy_media_unresolved');
      var ttk = hxqTokens[pid] && hxqTokens[pid].exp > Date.now() ? hxqTokens[pid].tok : '';
      if (!ttk) {
        var rw = hxqGet('/api/carp/reward/v2', { scene: 'ad_series_play' });
        var traceId = str(rw.traceId);
        if (traceId) {
          var md5U = md5Hex(hxqDev.uid);
          var postBody = JSON.stringify({
            data: aesCbcEncryptB64(JSON.stringify({ pid: pid, scene: 'ad_series_play', traceId: traceId }), md5U.slice(0, 16), md5U.slice(16, 32))
          });
          var hdrs = Object.assign(hxqHeaders(), {
            'Content-Type': 'application/json',
            aps: md5Hex(postBody + str(cfg.rewardAps))
          });
          var rpRes = httpReq(hxqHost + '/api/carp/reward/rp/v2', { method: 'POST', headers: hdrs, body: postBody });
          var rpDoc = parseJsonSafe(rpRes.content);
          var rpDec = isObj(rpDoc) && Number(rpDoc.rescode) === 0 ? hxqDecryptEnvelope(rpDoc) : null;
          if (isObj(rpDec) && isObj(rpDec.rewardTokenInfo)) {
            ttk = str(rpDec.rewardTokenInfo.token);
            if (ttk) hxqTokens[pid] = { tok: ttk, exp: Date.now() + 3600 * 1000 };
          }
        }
      }
      if (!ttk) fail('drpy_authentication_required');
      var sec = String(Math.floor(Date.now() / 1000));
      var rslvSign = md5Hex('&version=' + str(cfg.appVer) + '&uuid=' + hxqDev.uuid + '&udid=' + md5Hex(hxqDev.uid) + '&ttk=' + ttk + '&t=' + sec + '&sq=' + sq + '&scid=' + scid + '&re=' + re + '&pid=' + pid + str(cfg.rslvTail));
      var rslv = hxqGet('/api/series/rslvV4', {
        version: str(cfg.appVer), uuid: hxqDev.uuid, t: sec, sq: sq, scid: scid, re: re, pid: pid, dt: 'android', ttk: ttk, sign: rslvSign
      });
      var datas = Array.isArray(rslv.datas) ? rslv.datas : [];
      var fmt = Number(rslv.format) || 2;
      var urls = [], durs = [];
      for (var i = 0; i < datas.length; i++) {
        var row = datas[i];
        if (!isObj(row)) continue;
        var rawD = str(row.data || row.playUrl || row.url).trim();
        var decU = '';
        if (/^https?:\/\//i.test(rawD)) {
          decU = rawD;
        } else if (rawD) {
          var ivCandidates = [str(cfg.decodeKeyA), str(cfg.decodeKeyB)];
          for (var cIdx = 0; cIdx < ivCandidates.length && !decU; cIdx++) {
            try {
              var txt = hxqAesDecryptClean(rawD, str(cfg.decodeKeyC), ivCandidates[cIdx]);
              var j = txt.indexOf('{') === 0 ? parseJsonSafe(txt) : null;
              var cand = isObj(j) ? str(j.playUrl || j.url) : txt.trim();
              if (/^https?:\/\//i.test(cand)) decU = cand;
            } catch (_) {}
          }
        }
        if (decU) {
          urls.push(hxqRewriteCdn(decU));
          durs.push(String(Number(row.duration || row.dur) || 0));
        }
      }
      if (!urls.length) fail('drpy_media_unresolved');
      if (urls.length === 1) {
        if (/\.m3u8(?:[?#]|$)/i.test(urls[0])) {
          return { parse: 0, url: getProxy() + '&url=' + encodeURIComponent(urls[0]) };
        }
        return { parse: 0, url: address(urls[0]).url, header: { 'User-Agent': 'tdc.8260' } };
      }
      return {
        parse: 0,
        url: getProxy() + '&fmt=' + fmt + '&dur=' + encodeURIComponent(durs.join(',')) + '&url=' + encodeURIComponent(utf8ToB64(urls.join('|||')))
      };
    };
    __drpy.proxy = function (params) {
      var rawU = str(params && params.url).trim();
      if (!rawU) return [400, 'text/plain; charset=utf-8', 'Missing url'];
      var fmt = str(params && params.fmt).trim();
      if (!fmt && /^https?:\/\//i.test(rawU)) {
        var mIdx = rawU.indexOf('.m3u8');
        var suffix = mIdx > 0 ? rawU.slice(mIdx + 5) : '';
        var r = httpReq(rawU, { headers: { 'User-Agent': str(cfg.playUa) } });
        var body = str(r.content).replace(/\/m3u8\//g, str(cfg.m3u8CdnBase));
        if (suffix) body = body.split('.ts' + suffix).join('.ts');
        return [200, 'application/vnd.apple.mpegurl', body];
      }
      var listStr = '';
      try { listStr = b64ToUtf8(rawU); } catch (_) { listStr = rawU; }
      var segUrls = listStr.split('|||').map(function (x) { return hxqRewriteCdn(x); }).filter(function (x) { return /^https?:\/\//i.test(x); });
      if (!segUrls.length) return [502, 'text/plain; charset=utf-8', 'Empty segments'];
      var durArr = str(params && params.dur).split(',');
      if (Number(fmt) === 1) {
        var lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-MEDIA-SEQUENCE:0'];
        var maxDur = 10;
        for (var i = 0; i < segUrls.length; i++) {
          var rawDur = Number(durArr[i]) || 600;
          var secDur = rawDur > 10000 ? Math.max(1, Math.floor(rawDur / 1000)) : Math.max(1, rawDur);
          if (secDur > maxDur) maxDur = secDur;
          if (i > 0) lines.push('#EXT-X-DISCONTINUITY');
          lines.push('#EXTINF:' + secDur + '.000,');
          lines.push(segUrls[i]);
        }
        lines.splice(2, 0, '#EXT-X-TARGETDURATION:' + maxDur);
        lines.push('#EXT-X-ENDLIST');
        return [200, 'application/vnd.apple.mpegurl', lines.join('\n')];
      }
      var merged = ['#EXTM3U', '#EXT-X-VERSION:3'];
      var targetDur = 10, added = 0;
      for (var s = 0; s < segUrls.length; s++) {
        var sr = httpReqSoft(segUrls[s], { headers: { 'User-Agent': 'tdc.8260' }, timeout: 8000 });
        if (!sr || !str(sr.content)) continue;
        if (added > 0) merged.push('#EXT-X-DISCONTINUITY');
        var sLines = str(sr.content).split(/\r?\n/);
        for (var l = 0; l < sLines.length; l++) {
          var ln = sLines[l].trim();
          if (!ln || ln.indexOf('#EXTM3U') === 0 || ln.indexOf('#EXT-X-VERSION') === 0 || ln.indexOf('#EXT-X-MEDIA-SEQUENCE') === 0 || ln.indexOf('#EXT-X-ENDLIST') === 0) continue;
          if (ln.indexOf('#EXT-X-TARGETDURATION:') === 0) {
            var td = parseInt(ln.slice(22), 10) || 10;
            if (td > targetDur) targetDur = td;
            continue;
          }
          if (ln.charAt(0) !== '#') ln = joinUrl(segUrls[s], ln);
          merged.push(ln);
          added++;
        }
      }
      if (!added) return [502, 'text/plain; charset=utf-8', 'All segments failed'];
      merged.splice(2, 0, '#EXT-X-TARGETDURATION:' + targetDur, '#EXT-X-MEDIA-SEQUENCE:0');
      merged.push('#EXT-X-ENDLIST');
      return [200, 'application/vnd.apple.mpegurl', merged.join('\n')];
    };
    return;
  }

  fail('drpy_source_unavailable');
}

module.exports = function wexVodRule(config) {
  if (!config || !VOD_WEX_ADAPTERS.includes(config.adapter) || !/^https?:\/\//.test(config.origin)) {
    throw Error('endpoint configuration required');
  }
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:12000,预处理:"js:rule._install();",_install:' + installWexVod.toString() + '};';
};

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';

const LIVE_ADAPTERS = Object.freeze([
  'kanqiu-v1', 'doubao-v1', 'livegz-v1', 'alllive-v1', 'tingshu275-v1', 'yueting-v1'
]);

function installFtyLive() {
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
  function utf8ToB64(s) { return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(str(s))); }
  function b64ToUtf8(b) {
    var clean = str(b).trim().replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    return CryptoJS.enc.Base64.parse(clean).toString(CryptoJS.enc.Utf8);
  }
  function bytesToB64(u8) {
    var words = [];
    for (var i = 0; i < u8.length; i++) words[i >>> 2] |= (u8[i] & 0xff) << (24 - (i % 4) * 8);
    return CryptoJS.enc.Base64.stringify(CryptoJS.lib.WordArray.create(words, u8.length));
  }
  function b64ToBytes(b64) {
    var clean = str(b64).trim().replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4) clean += '=';
    var wa = CryptoJS.enc.Base64.parse(clean);
    var out = new Uint8Array(wa.sigBytes);
    for (var i = 0; i < wa.sigBytes; i++) out[i] = (wa.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
    return out;
  }
  function hexToBytes(hex) {
    var h = str(hex).replace(/\s+/g, '');
    var out = new Uint8Array(Math.floor(h.length / 2));
    for (var i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16) || 0;
    return out;
  }
  function bytesToHex(u8) {
    var s = '';
    for (var i = 0; i < u8.length; i++) s += ('0' + (u8[i] & 0xff).toString(16)).slice(-2);
    return s;
  }
  function httpReq(url, opts) {
    var r;
    try { r = req(url, Object.assign({ timeout: 10000 }, opts || {})); }
    catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    if (!r || typeof r.content !== 'string') fail('drpy_source_unavailable');
    if (!opts || opts.buffer !== 2) checkChallenge(r.content);
    return r;
  }

  // ==================== 1. kanqiu-v1 (88看球) ====================
  if (cfg.adapter === 'kanqiu-v1') {
    var kqHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    var kqHdr = { 'User-Agent': cfg.userAgent, Referer: kqHost + '/' };
    function xxteaDecryptB64(dataB64, keyStr) {
      var data = b64ToBytes(dataB64);
      if (!data.length) return '';
      function toU32(bytes, includeLen) {
        var n = (bytes.length & 3) === 0 ? (bytes.length >>> 2) : ((bytes.length >>> 2) + 1);
        var v = new Uint32Array(includeLen ? n + 1 : n);
        if (includeLen) v[n] = bytes.length;
        for (var i = 0; i < bytes.length; i++) v[i >>> 2] |= bytes[i] << ((i & 3) << 3);
        return v;
      }
      var v = toU32(data, false);
      var kBytes = new Uint8Array(16);
      for (var ki = 0; ki < 16 && ki < keyStr.length; ki++) kBytes[ki] = keyStr.charCodeAt(ki) & 0xff;
      var k = toU32(kBytes, false);
      var n = v.length - 1;
      if (n < 1) return '';
      var z, y = v[0], delta = 0x9E3779B9, q = Math.floor(6 + 52 / (n + 1)), sum = (q * delta) >>> 0;
      while (sum !== 0) {
        var e = (sum >>> 2) & 3;
        for (var p = n; p > 0; p--) {
          z = v[p - 1];
          var mx = (((z >>> 5) ^ (y << 2)) + ((y >>> 3) ^ (z << 4))) ^ ((sum ^ y) + (k[(p & 3) ^ e] ^ z));
          y = v[p] = (v[p] - mx) >>> 0;
        }
        z = v[n];
        var mx0 = (((z >>> 5) ^ (y << 2)) + ((y >>> 3) ^ (z << 4))) ^ ((sum ^ y) + (k[e] ^ z));
        y = v[0] = (v[0] - mx0) >>> 0;
        sum = (sum - delta) >>> 0;
      }
      var mLen = v[n];
      var totalBytes = n * 4;
      if (mLen < 0 || mLen > totalBytes) mLen = totalBytes;
      var out = new Uint8Array(mLen);
      for (var bi = 0; bi < mLen; bi++) out[bi] = (v[bi >>> 2] >>> ((bi & 3) << 3)) & 0xff;
      return b64ToUtf8(bytesToB64(out));
    }

    __drpy.home = function () {
      var filters = {};
      try { filters = JSON.parse(cfg.filtersJson); } catch (_) {}
      return {
        class: [
          { type_id: 'all', type_name: '全部比赛' },
          { type_id: '1', type_name: '篮球' },
          { type_id: '8', type_name: '足球' },
          { type_id: '29', type_name: '其他综合' }
        ],
        filters: filters
      };
    };
    __drpy.homeVod = function () {
      return __drpy.category('all', 1, true, {});
    };
    __drpy.category = function (tid, pg, filter, extend) {
      var cat = str((extend && extend.cateId) || tid);
      var targetUrl = (cat && cat !== 'all') ? (kqHost + '/match/' + encodeURIComponent(cat) + '/live') : (kqHost + '/');
      var html = httpReq(targetUrl, { headers: kqHdr }).content;
      var items = pdfa(html, '.list-group-item');
      var list = items.map(function (it) {
        var btn = pdfh(it, '.btn.btn-primary&&href') || pdfh(it, 'a[href*="/match/"]&&href');
        var title = stripHtml(pdfh(it, '.row&&Html') || pdfh(it, '.list-group-item&&Text'));
        if (!btn || !title) return null;
        var status = pdfh(it, '.btn.btn-primary&&Text') || pdfh(it, '.btn.btn-default&&Text') || '直播';
        var img = pdfh(it, 'img&&src');
        return {
          vod_id: btn,
          vod_name: title,
          vod_pic: safePic(img, kqHost + '/'),
          vod_remarks: status
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: list.length || 20, total: list.length, list: list };
    };
    __drpy.search = function () { return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] }; };
    __drpy.detail = function (id) {
      var u = address(id, kqHost + '/').url;
      var html = httpReq(u, { headers: kqHdr }).content;
      var linksUrl = u.replace(/\/$/, '') + '-links';
      var eps = [];
      try {
        var lr = req(linksUrl, { timeout: 6000, headers: Object.assign({ 'X-Requested-With': 'XMLHttpRequest' }, kqHdr) });
        if (lr && lr.code === 200 && typeof lr.content === 'string') {
          var decText = lr.content.trim();
          if (decText.charAt(0) !== '{' && decText.charAt(0) !== '[') {
            try { decText = xxteaDecryptB64(decText.replace(/^"+|"+$/g, ''), cfg.xxteaKey); } catch (_) {}
          }
          var lDoc = JSON.parse(decText);
          var arr = Array.isArray(lDoc) ? lDoc : (isObj(lDoc) && Array.isArray(lDoc.links) ? lDoc.links : (isObj(lDoc) && Array.isArray(lDoc.data) ? lDoc.data : []));
          arr.forEach(function (lk, idx) {
            if (isObj(lk) && (lk.url || lk.id)) {
              eps.push(str(lk.name || ('信号' + (idx + 1))).replace(/[$#]/g, ' ') + '$' + str(lk.url || lk.id));
            }
          });
        }
      } catch (_) {}
      if (!eps.length) {
        pdfa(html, 'a[data-url], .play-btn, a[href*="play"]').forEach(function (a, idx) {
          var du = pdfh(a, 'a&&data-url') || pdfh(a, 'a&&href');
          var nm = pdfh(a, 'a&&Text') || ('直播源' + (idx + 1));
          if (du) eps.push(nm.replace(/[$#]/g, ' ').trim() + '$' + du);
        });
      }
      return {
        list: [{
          vod_id: str(id),
          vod_name: stripHtml(pdfh(html, 'title&&Text')) || '体育直播',
          vod_pic: safePic(pdfh(html, 'img.team-logo&&src'), kqHost + '/'),
          vod_content: stripHtml(pdfh(html, 'title&&Text')),
          vod_play_from: eps.length ? '看球直播' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var raw = str(id).trim();
      if (/\.(?:m3u8|flv|mp4)(?:[?#]|$)/i.test(raw)) {
        return { parse: 0, url: address(raw, kqHost + '/').url, header: kqHdr };
      }
      var pageUrl = address(raw, kqHost + '/').url;
      var html = httpReq(pageUrl, { headers: kqHdr }).content;
      var m = /["'](https?:\/\/[^"']+\.(?:m3u8|flv|mp4)[^"']*)["']/i.exec(html);
      if (m && m[1]) return { parse: 0, url: address(m[1]).url, header: { 'User-Agent': cfg.userAgent, Referer: pageUrl } };
      fail('drpy_media_unresolved');
    };
    return;
  }

  // ==================== 2. doubao-v1 (豆包看球) ====================
  if (cfg.adapter === 'doubao-v1') {
    var dbHost = str(cfg.defaultHost).replace(/\/+$/, '');
    var dbHdr = { 'User-Agent': cfg.userAgent, Accept: 'application/json', 'Accept-Language': 'zh-CN,zh;q=0.9', Referer: dbHost + '/' };
    var isHomeSched = /\/home\/schedules/.test(str(cfg.scheduleUrl));

    function dbGet(u) {
      var r = httpReq(u, { headers: dbHdr });
      if (r.code < 200 || r.code >= 300) fail();
      var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      return isObj(doc) ? (doc.data !== undefined ? doc.data : doc) : {};
    }
    function dbMatchTitle(m) {
      var a = str(m.teamAName || m.homeTeamName || (m.homeTeam && m.homeTeam.name)).trim();
      var b = str(m.teamBName || m.awayTeamName || (m.awayTeam && m.awayTeam.name)).trim();
      var lg = str(m.leagueName || m.competitionName || '').trim();
      if (a && b) return (lg ? ('[' + lg + '] ') : '') + a + ' VS ' + b;
      return str(m.title || m.name || lg || '赛事直播').trim();
    }
    function dbFetchLiveMatches() {
      var today = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
      var u = isHomeSched
        ? (cfg.scheduleUrl + '?startDate=' + today + '&days=5&category=all&continuous=true&pageSize=30&q=')
        : cfg.scheduleUrl;
      var d = dbGet(u);
      var matches = [];
      if (isObj(d) && Array.isArray(d.items)) {
        d.items.forEach(function (it) {
          var m = isObj(it) && isObj(it.schedule) ? it.schedule : (isObj(it) && isObj(it.match) ? it.match : it);
          if (isObj(m)) matches.push(m);
        });
      } else if (isObj(d) && Array.isArray(d.days)) {
        d.days.forEach(function (day) {
          var arr = isObj(day) ? (day.live || day.schedules || day.list || []) : [];
          if (Array.isArray(arr)) arr.forEach(function (m) { if (isObj(m)) matches.push(m); });
        });
      } else if (Array.isArray(d)) {
        d.forEach(function (m) { if (isObj(m)) matches.push(m); });
      }
      return matches;
    }

    __drpy.home = function () {
      return {
        class: [
          { type_id: 'live', type_name: '赛事直播' },
          { type_id: 'replay_football', type_name: '足球回放' },
          { type_id: 'replay_basketball', type_name: '篮球回放' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () {
      return __drpy.category('live', 1, false, {});
    };
    __drpy.category = function (tid, pg) {
      var page = Math.max(1, Number(pg) || 1);
      if (tid === 'replay_football' || tid === 'replay_basketball') {
        var dt = tid === 'replay_football' ? 'football' : 'basketball';
        var pd = dbGet(cfg.playbackUrl + '?page=' + page + '&pageSize=20&dataType=' + dt);
        var items = isObj(pd) && Array.isArray(pd.items) ? pd.items : (Array.isArray(pd) ? pd : []);
        var list = items.map(function (it) {
          if (!isObj(it)) return null;
          var pb = isObj(it.playback) ? it.playback : it;
          var sc = isObj(it.schedule) ? it.schedule : it;
          var pid = str(pb.id || it.id).trim();
          if (!pid) return null;
          return {
            vod_id: 'replay###' + pid,
            vod_name: dbMatchTitle(sc),
            vod_pic: safePic(sc.teamAImage || sc.homeTeamLogo, dbHost + '/'),
            vod_remarks: '全场回放'
          };
        }).filter(Boolean);
        return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: 999, list: list };
      }
      var matches = dbFetchLiveMatches();
      var vods = matches.map(function (m) {
        var mid = str(m.id || m.scheduleId).trim();
        if (!mid) return null;
        return {
          vod_id: 'live###' + mid,
          vod_name: dbMatchTitle(m),
          vod_pic: safePic(m.teamAImage || m.homeTeamLogo, dbHost + '/'),
          vod_remarks: str(m.startTime || m.matchTime || '').replace('T', ' ').slice(5, 16)
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: vods.length || 30, total: vods.length, list: vods };
    };
    __drpy.search = function () { return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] }; };
    __drpy.detail = function (id) {
      var raw = str(id);
      if (raw.indexOf('replay###') === 0) {
        var rId = raw.slice(9);
        for (var p = 1; p <= 4; p++) {
          var pd = dbGet(cfg.playbackUrl + '?page=' + p + '&pageSize=20&dataType=all');
          var items = isObj(pd) && Array.isArray(pd.items) ? pd.items : [];
          for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var pb = isObj(it.playback) ? it.playback : it;
            if (str(pb.id || it.id) === rId) {
              var sc = isObj(it.schedule) ? it.schedule : it;
              var lines = Array.isArray(pb.lines) ? pb.lines : [];
              var eps = lines.map(function (ln, idx) {
                var pu = str(ln.proxyUrl || ln.url).trim();
                if (!pu) return '';
                if (pu.charAt(0) === '/') pu = dbHost + pu;
                return str(ln.title || ('回放' + (idx + 1))).replace(/[$#]/g, ' ') + '$' + pu;
              }).filter(Boolean);
              return {
                list: [{
                  vod_id: raw,
                  vod_name: dbMatchTitle(sc),
                  vod_pic: safePic(sc.teamAImage, dbHost + '/'),
                  vod_content: dbMatchTitle(sc),
                  vod_play_from: eps.length ? '全场回放' : '',
                  vod_play_url: eps.join('#')
                }]
              };
            }
          }
        }
        fail('drpy_source_response');
      }
      var mId = raw.replace(/^live###/, '');
      var epsLive = [];
      var title = '赛事直播', pic = '';
      var matches = dbFetchLiveMatches();
      matches.forEach(function (m) {
        if (str(m.id || m.scheduleId) === mId) {
          title = dbMatchTitle(m);
          pic = safePic(m.teamAImage || m.homeTeamLogo, dbHost + '/');
          if (Array.isArray(m.signals)) {
            m.signals.forEach(function (sg, idx) {
              var u = str(sg.url || sg.playUrl || sg.playId).trim();
              if (u) epsLive.push(str(sg.name || ('信号' + (idx + 1))).replace(/[$#]/g, ' ') + '$' + u);
            });
          }
        }
      });
      if (!epsLive.length) {
        try {
          var sd = dbGet(dbHost + '/api/v1/public/signals/' + encodeURIComponent(mId));
          var sigs = Array.isArray(sd) ? sd : (isObj(sd) && Array.isArray(sd.signals) ? sd.signals : (isObj(sd) && Array.isArray(sd.items) ? sd.items : []));
          sigs.forEach(function (sg, idx) {
            var u = str(sg.url || sg.playUrl || sg.streamUrl || sg.id).trim();
            if (u) epsLive.push(str(sg.name || sg.title || ('信号' + (idx + 1))).replace(/[$#]/g, ' ') + '$' + u);
          });
        } catch (_) { globalThis.__drpyUnsupported = null; }
      }
      return {
        list: [{
          vod_id: raw,
          vod_name: title,
          vod_pic: pic,
          vod_content: title,
          vod_play_from: epsLive.length ? '直播信号' : '',
          vod_play_url: epsLive.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var raw = str(id).trim();
      if (/^https?:\/\//i.test(raw)) return { parse: 0, url: address(raw, dbHost + '/').url, header: dbHdr };
      var sd = dbGet(dbHost + '/api/v1/public/signals/' + encodeURIComponent(raw));
      var u = str(isObj(sd) ? (sd.url || sd.playUrl || sd.streamUrl) : '').trim();
      if (!u) fail('drpy_media_unresolved');
      return { parse: 0, url: address(u, dbHost + '/').url, header: dbHdr };
    };
    return;
  }

  // ==================== 3. livegz-v1 (吃瓜看球) ====================
  if (cfg.adapter === 'livegz-v1') {
    var gzHost = (str(cfg.extText).match(/^https?:\/\/[^\s|,;]+/i) ? str(cfg.extText).split(/[|,;\s]+/)[0] : str(cfg.defaultHost)).replace(/\/+$/, '');
    function gzEnc(jsonStr) {
      return nodeCipher('encrypt', 'aes-128-cbc', utf8ToB64(cfg.aesKey), utf8ToB64(cfg.aesIv), utf8ToB64(jsonStr), '').data;
    }
    function gzDec(cipherText) {
      var clean = str(cipherText).trim().replace(/^"+|"+$/g, '');
      if (clean.charAt(0) === '{' || clean.charAt(0) === '[') return JSON.parse(clean);
      var plain = b64ToUtf8(nodeCipher('decrypt', 'aes-128-cbc', utf8ToB64(cfg.aesKey), utf8ToB64(cfg.aesIv), clean, '').data);
      return JSON.parse(plain);
    }
    function gzPost(path, payloadObj) {
      var paramVal = gzEnc(JSON.stringify(payloadObj));
      var r = httpReq(gzHost + path, {
        method: 'POST',
        headers: {
          'User-Agent': cfg.userAgent,
          'client-version': cfg.clientVersion,
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: 'parameter=' + encodeURIComponent(paramVal)
      });
      if (r.code < 200 || r.code >= 300) fail();
      var outer = gzDec(r.content);
      if (isObj(outer) && typeof outer.data === 'string') return gzDec(outer.data);
      return isObj(outer) && outer.data !== undefined ? outer.data : outer;
    }

    __drpy.home = function () {
      return {
        class: [
          { type_id: '1-hot', type_name: '热门赛事' },
          { type_id: '1-0', type_name: '足球' },
          { type_id: '2-0', type_name: '篮球' }
        ],
        filters: {}
      };
    };
    __drpy.homeVod = function () { return __drpy.category('1-hot', 1, false, {}); };
    __drpy.category = function (tid) {
      var parts = str(tid).split('-');
      var bType = parts[0] || '1';
      var isHot = parts[1] === 'hot' ? '1' : '0';
      var d = gzPost(cfg.sportsPath, { frame: '0', hot: isHot, tag: '', type: bType });
      var arr = Array.isArray(d) ? d : (isObj(d) && Array.isArray(d.list) ? d.list : []);
      var list = arr.map(function (it) {
        if (!isObj(it)) return null;
        var mid = str(it.match_id || it.id).trim();
        var bt = str(it.ball_type || bType);
        var home = str(it.home_name || it.team_a || '').trim();
        var away = str(it.away_name || it.team_b || '').trim();
        var lg = str(it.league_name || it.event_name || '').trim();
        if (!mid) return null;
        return {
          vod_id: bt + '###' + mid,
          vod_name: (lg ? ('[' + lg + '] ') : '') + (home && away ? (home + ' VS ' + away) : str(it.title || mid)),
          vod_pic: safePic(it.home_logo || it.pic, gzHost + '/'),
          vod_remarks: str(it.match_time || it.m_status || '')
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: list.length || 20, total: list.length, list: list };
    };
    __drpy.search = function () { return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] }; };
    __drpy.detail = function (id) {
      var sp = str(id).split('###');
      var bt = sp[0] || '1', mid = sp[1] || sp[0];
      var d = gzPost(cfg.detailPath, { ball_type: bt, match_id: mid });
      var lines = isObj(d) && Array.isArray(d.live_line) ? d.live_line : (Array.isArray(d) ? d : []);
      var eps = [];
      lines.forEach(function (ln, idx) {
        if (!isObj(ln)) return;
        var u = str(ln.url || ln.play_url || ln.live_url).trim();
        if (u && /^https?:\/\//i.test(u)) {
          eps.push(str(ln.name || ln.title || ('信号' + (idx + 1))).replace(/[$#]/g, ' ') + '$' + u);
        }
      });
      return {
        list: [{
          vod_id: str(id),
          vod_name: str((isObj(d) && (d.title || (d.home_name && (d.home_name + ' VS ' + d.away_name)))) || '赛事直播'),
          vod_pic: safePic(isObj(d) ? d.home_logo : '', gzHost + '/'),
          vod_content: '体育赛事直播',
          vod_play_from: eps.length ? '高清直播' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      return { parse: 0, url: address(id).url, header: { 'User-Agent': cfg.userAgent } };
    };
    return;
  }

  // ==================== 4. alllive-v1 (Alllive / 一直播) ====================
  if (cfg.adapter === 'alllive-v1') {
    var alBase = str(cfg.ext && (cfg.ext.host || cfg.ext.url) || cfg.extText || cfg.origin).split(/[|,;\s]+/)[0].replace(/\/+$/, '');
    var huyaUid = '';
    var alInited = false;
    function ensureAlInit() {
      if (alInited) return;
      alInited = true;
      try {
        var r = req(cfg.huyaLoginUrl, {
          method: 'POST',
          timeout: 4000,
          headers: { 'Content-Type': 'application/json' },
          body: cfg.huyaLoginBody
        });
        if (r && r.code === 200 && typeof r.content === 'string') {
          var d = JSON.parse(r.content);
          if (d && d.data && d.data.uid) huyaUid = str(d.data.uid);
        }
      } catch (_) {}
      if (!huyaUid) huyaUid = '146229' + String(Math.floor(100000 + Math.random() * 899999));
    }
    function alGet(path) {
      var r = httpReq(alBase + path, { headers: { 'sec-fetch-site': 'same-origin', Accept: 'application/json' } });
      if (r.code < 200 || r.code >= 300) fail();
      var doc; try { doc = JSON.parse(r.content); } catch (_) { fail('drpy_source_response'); }
      return isObj(doc) && doc.data !== undefined ? doc.data : doc;
    }

    __drpy.home = function () {
      return {
        class: [
          { type_id: 'huya', type_name: '虎牙' },
          { type_id: 'douyu', type_name: '斗鱼' },
          { type_id: 'bilibili', type_name: '哔哩' }
        ],
        filters: {
          huya: [{ key: 'type', name: '分类', value: [{ n: '网游', v: '1' }, { n: '单机', v: '2' }, { n: '娱乐', v: '8' }, { n: '手游', v: '3' }] }],
          douyu: [{ key: 'type', name: '分类', value: [{ n: '网游竞技', v: 'PCgame' }, { n: '单机热游', v: 'djry' }, { n: '手游休闲', v: 'syxx' }, { n: '娱乐天地', v: 'yl' }] }]
        }
      };
    };
    __drpy.homeVod = function () { return __drpy.category('huya', 1, true, { type: '1' }); };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var platform = str(tid);
      var sub = str((extend && extend.type) || (platform === 'douyu' ? 'PCgame' : '1'));
      var path = platform === 'bilibili'
        ? ('/api/bilibili/getRecommendRooms?page=' + page)
        : ('/api/' + encodeURIComponent(platform) + '/getCategoryRooms?id=' + encodeURIComponent(sub) + '&pid=1&page=' + page);
      var d = alGet(path);
      var arr = isObj(d) && Array.isArray(d.items) ? d.items : (isObj(d) && Array.isArray(d.list) ? d.list : (Array.isArray(d) ? d : []));
      var list = arr.map(function (rm) {
        if (!isObj(rm)) return null;
        var rid = str(rm.roomId || rm.id).trim();
        var title = str(rm.title || rm.roomName).trim();
        if (!rid || !title) return null;
        return {
          vod_id: platform + '_' + rid,
          vod_name: title,
          vod_pic: safePic(rm.cover || rm.pic),
          vod_remarks: str(rm.userName || rm.online || '')
        };
      }).filter(Boolean);
      return { page: page, pagecount: list.length >= 15 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var out = [];
      ['huya', 'douyu'].forEach(function (pf) {
        try {
          var d = alGet('/api/' + pf + '/searchRooms?keyword=' + encodeURIComponent(kw) + '&page=' + page);
          var arr = isObj(d) && Array.isArray(d.items) ? d.items : (Array.isArray(d) ? d : []);
          arr.forEach(function (rm) {
            if (isObj(rm) && (rm.roomId || rm.id) && rm.title) {
              out.push({
                vod_id: pf + '_' + str(rm.roomId || rm.id),
                vod_name: '[' + (pf === 'huya' ? '虎牙' : '斗鱼') + '] ' + str(rm.title),
                vod_pic: safePic(rm.cover),
                vod_remarks: str(rm.userName || '')
              });
            }
          });
        } catch (_) { globalThis.__drpyUnsupported = null; }
      });
      return { page: page, pagecount: 1, limit: out.length || 20, total: out.length, list: out };
    };
    __drpy.detail = function (id) {
      ensureAlInit();
      var idx = str(id).indexOf('_');
      var pf = idx > 0 ? str(id).slice(0, idx) : 'huya';
      var rid = idx > 0 ? str(id).slice(idx + 1) : str(id);
      var d = alGet('/api/' + encodeURIComponent(pf) + '/getRoomDetail?id=' + encodeURIComponent(rid));
      var suffix = '';
      if (pf === 'huya' && isObj(d) && isObj(d.huya)) {
        try {
          var sName = str(d.huya.name);
          var anti = str(d.huya.anti || d.huya.flvAntiCode);
          var qMap = Object.create(null);
          anti.replace(/^\?/, '').split('&').forEach(function (kv) {
            var eq = kv.indexOf('=');
            if (eq > 0) qMap[kv.slice(0, eq)] = decodeURIComponent(kv.slice(eq + 1));
          });
          if (qMap.fm) {
            var nowMs = Date.now();
            var wsTime = Math.floor(nowMs / 1000 + 21600).toString(16);
            var seqid = String((Number(huyaUid) || 0) + nowMs * 1000);
            var fmPrefix = b64ToUtf8(qMap.fm).split('_')[0];
            var ctype = qMap.ctype || 'huya_live';
            var ss = CryptoJS.MD5(seqid + '|' + ctype + '|100').toString();
            var wsSecret = CryptoJS.MD5([fmPrefix, huyaUid, sName, ss, wsTime].join('_')).toString();
            suffix = '?wsSecret=' + wsSecret + '&wsTime=' + wsTime + '&seqid=' + seqid + '&ctype=' + ctype + '&ver=1&fs=' + (qMap.fs || 'bgct') + '&t=100&u=' + huyaUid;
          }
        } catch (_) {}
      }
      var froms = [], groups = [];
      var streams = isObj(d) && Array.isArray(d.stream) ? d.stream : [];
      streams.forEach(function (st, sIdx) {
        if (!isObj(st)) return;
        var stName = str(st.name || ('清晰度' + (sIdx + 1))).trim();
        var lines = Array.isArray(st.lines) ? st.lines : [];
        var eps = [];
        lines.forEach(function (ln, lIdx) {
          if (!isObj(ln) || !ln.url) return;
          var u = str(ln.url).trim();
          if (suffix && u.indexOf('wsSecret=') < 0) u = u.split('?')[0] + suffix;
          eps.push(str(ln.name || ('线路' + (lIdx + 1))).replace(/[$#]/g, ' ') + '$' + u);
        });
        if (eps.length) {
          froms.push(stName);
          groups.push(eps.join('#'));
        }
      });
      return {
        list: [{
          vod_id: str(id),
          vod_name: str(isObj(d) ? (d.title || rid) : rid),
          vod_pic: safePic(isObj(d) ? d.cover : ''),
          vod_actor: str(isObj(d) ? d.userName : ''),
          vod_content: stripHtml(isObj(d) ? d.introduction || d.title : ''),
          vod_play_from: froms.join('$$$'),
          vod_play_url: groups.join('$$$')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      var u = str(id).trim();
      if (u.indexOf('//') === 0) u = 'https:' + u;
      return { parse: 0, url: address(u).url, header: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' } };
    };
    return;
  }

  // ==================== 5. tingshu275-v1 (275听书) ====================
  if (cfg.adapter === 'tingshu275-v1') {
    var tsBase = str(cfg.defaultHost).replace(/\/+$/, '') + '/';
    var tsInited = false;
    function ensureTsHost() {
      if (tsInited) return;
      tsInited = true;
      try {
        var r = req(cfg.configUrl, { timeout: 3500, headers: { 'User-Agent': cfg.apiUa } });
        if (r && r.code === 200 && typeof r.content === 'string') {
          var cand = r.content.trim().split(/[\r\n\s]+/)[0];
          if (/^https?:\/\//i.test(cand)) tsBase = cand.replace(/\/+$/, '') + '/';
        }
      } catch (_) {}
    }
    function tsGet(relUrl) {
      ensureTsHost();
      var u = /^https?:\/\//i.test(relUrl) ? relUrl : (tsBase + relUrl.replace(/^\/+/, ''));
      var r = httpReq(u, { headers: { 'User-Agent': cfg.apiUa } });
      if (r.code < 200 || r.code >= 300) fail();
      return JSON.parse(r.content);
    }

    __drpy.home = function () {
      var ids = ['6', '7', '8', '9', '10', '11', '12', '13', '14', '15', '49'];
      var names = ['玄幻奇幻', '都市言情', '宫斗女频', '官场商战', '武侠仙侠', '刑侦推理', '探险科幻', '重生穿越', '恐怖惊悚', '文学历史', '两性情感'];
      return {
        class: ids.map(function (id, i) { return { type_id: id, type_name: names[i] }; }),
        filters: {}
      };
    };
    __drpy.homeVod = function () { return __drpy.category('6', 1, false, {}); };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var cid = str((extend && extend.cateId) || tid);
      var doc = tsGet('categoryList?size=10&page=' + page + '&categoryId=' + encodeURIComponent(cid));
      var arr = isObj(doc) && isObj(doc.data) && Array.isArray(doc.data.list) ? doc.data.list : [];
      var list = arr.map(function (it) {
        if (!isObj(it) || !it.id || !it.bookTitle) return null;
        return {
          vod_id: str(it.id),
          vod_name: str(it.bookTitle),
          vod_pic: safePic(it.bookImage, tsBase),
          vod_remarks: str(it.bookAnchor)
        };
      }).filter(Boolean);
      return { page: page, pagecount: list.length >= 10 ? page + 1 : page, limit: 10, total: 999, list: list };
    };
    __drpy.search = function (wd) {
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 10, total: 0, list: [] };
      var doc = tsGet('listen/apphaidao/appSearch?search=' + encodeURIComponent(kw));
      var arr = isObj(doc) && isObj(doc.data) && Array.isArray(doc.data.bookData) ? doc.data.bookData : [];
      var list = arr.map(function (it) {
        if (!isObj(it) || !it.id || !it.bookTitle) return null;
        return {
          vod_id: str(it.id),
          vod_name: str(it.bookTitle),
          vod_pic: safePic(it.bookImage, tsBase),
          vod_remarks: str(it.bookAnchor)
        };
      }).filter(Boolean);
      return { page: 1, pagecount: 1, limit: list.length || 10, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var bid = str(id).trim();
      var bDoc = tsGet('book?bookId=' + encodeURIComponent(bid));
      var bd = isObj(bDoc) && isObj(bDoc.data) && isObj(bDoc.data.bookData) ? bDoc.data.bookData : {};
      var cDoc = tsGet('chapter?size=9999&page=1&sort=asc&bookId=' + encodeURIComponent(bid));
      var chs = isObj(cDoc) && isObj(cDoc.data) && Array.isArray(cDoc.data.list) ? cDoc.data.list : [];
      var eps = chs.map(function (ch, idx) {
        if (!isObj(ch) || !ch.chapterId) return '';
        return str(ch.title || ('第' + (idx + 1) + '章')).replace(/[$#]/g, ' ') + '$' + str(ch.chapterId) + '|||' + bid;
      }).filter(Boolean);
      return {
        list: [{
          vod_id: bid,
          vod_name: str(bd.bookTitle || bid),
          vod_pic: safePic(bd.bookImage, tsBase),
          type_name: str(bd.categoryName),
          vod_actor: str(bd.bookAnchor),
          vod_director: str(bd.bookAnchor),
          vod_content: stripHtml(bd.bookDesc),
          vod_play_from: eps.length ? '直链' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      ensureTsHost();
      var sp = str(id).split('|||');
      var chId = sp[0] || '', bId = sp[1] || '';
      var ts = String(Date.now());
      var sign = CryptoJS.MD5(ts).toString();
      var doc = tsGet('AppGetChapterUrl2023?timeStamp=' + ts + '&uid=&chapterId=' + encodeURIComponent(chId) + '&addItParapet=' + sign + '&bookId=' + encodeURIComponent(bId));
      var src = str(isObj(doc) ? (doc.src || (isObj(doc.data) ? doc.data.src : '')) : '').trim();
      if (!src) fail('drpy_media_unresolved');
      return { parse: 0, url: address(src, tsBase).url, header: { 'User-Agent': cfg.playUa } };
    };
    return;
  }

  // ==================== 6. yueting-v1 (悦听有声) ====================
  if (cfg.adapter === 'yueting-v1') {
    var ytKeyBytes = hexToBytes(cfg.keyHex);
    var ytSession = (function () {
      var r = new Uint8Array(16);
      crypto.getRandomValues(r);
      var h = bytesToHex(r);
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-4' + h.slice(13, 16) + '-a' + h.slice(17, 20) + '-' + h.slice(20, 32);
    })();
    var ytApiHosts = [];

    function rotl32(v, c) { return ((v << c) | (v >>> (32 - c))) >>> 0; }
    function readLE32(b, o) { return ((b[o]) | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0; }
    function writeLE32(b, o, v) {
      b[o] = v & 0xff; b[o + 1] = (v >>> 8) & 0xff; b[o + 2] = (v >>> 16) & 0xff; b[o + 3] = (v >>> 24) & 0xff;
    }
    function qRound(s, a, b, c, d) {
      s[a] = (s[a] + s[b]) >>> 0; s[d] = rotl32(s[d] ^ s[a], 16);
      s[c] = (s[c] + s[d]) >>> 0; s[b] = rotl32(s[b] ^ s[c], 12);
      s[a] = (s[a] + s[b]) >>> 0; s[d] = rotl32(s[d] ^ s[a], 8);
      s[c] = (s[c] + s[d]) >>> 0; s[b] = rotl32(s[b] ^ s[c], 7);
    }
    function hChaCha20(key32, nonce16) {
      var s = new Uint32Array([
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        readLE32(key32, 0), readLE32(key32, 4), readLE32(key32, 8), readLE32(key32, 12),
        readLE32(key32, 16), readLE32(key32, 20), readLE32(key32, 24), readLE32(key32, 28),
        readLE32(nonce16, 0), readLE32(nonce16, 4), readLE32(nonce16, 8), readLE32(nonce16, 12)
      ]);
      for (var i = 0; i < 10; i++) {
        qRound(s, 0, 4, 8, 12); qRound(s, 1, 5, 9, 13); qRound(s, 2, 6, 10, 14); qRound(s, 3, 7, 11, 15);
        qRound(s, 0, 5, 10, 15); qRound(s, 1, 6, 11, 12); qRound(s, 2, 7, 8, 13); qRound(s, 3, 4, 9, 14);
      }
      var out = new Uint8Array(32);
      writeLE32(out, 0, s[0]); writeLE32(out, 4, s[1]); writeLE32(out, 8, s[2]); writeLE32(out, 12, s[3]);
      writeLE32(out, 16, s[12]); writeLE32(out, 20, s[13]); writeLE32(out, 24, s[14]); writeLE32(out, 28, s[15]);
      return out;
    }

    function ytDecryptPayload(hexStr) {
      var raw = hexToBytes(hexStr);
      if (raw.length < 41) fail('drpy_crypto_invalid');
      var nonce24 = raw.subarray(1, 25);
      var cipher = raw.subarray(25, raw.length - 16);
      var tag16 = raw.subarray(raw.length - 16);
      var subKey = hChaCha20(ytKeyBytes, nonce24.subarray(0, 16));
      var ietfNonce = new Uint8Array(12);
      ietfNonce.set(nonce24.subarray(16, 24), 4);
      var dec = nodeCipher('decrypt', 'chacha20-poly1305', bytesToB64(subKey), bytesToB64(ietfNonce), bytesToB64(cipher), bytesToB64(tag16));
      return JSON.parse(b64ToUtf8(dec.data));
    }

    function ytEncryptGcm(jsonStr) {
      var iv12 = new Uint8Array(12);
      crypto.getRandomValues(iv12);
      var enc = nodeCipher('encrypt', 'aes-256-gcm', bytesToB64(ytKeyBytes), bytesToB64(iv12), utf8ToB64(jsonStr), '');
      var cBytes = b64ToBytes(enc.data);
      var tBytes = b64ToBytes(enc.tag);
      var out = new Uint8Array(1 + 12 + cBytes.length + tBytes.length);
      out[0] = 1;
      out.set(iv12, 1);
      out.set(cBytes, 13);
      out.set(tBytes, 13 + cBytes.length);
      return bytesToHex(out);
    }

    function ytGetJson(url) {
      var r = httpReq(url, { headers: { 'User-Agent': cfg.apiUa } });
      if (r.code < 200 || r.code >= 300) fail();
      var outer = JSON.parse(r.content);
      return outer && outer.payload ? ytDecryptPayload(outer.payload) : outer;
    }

    function ytCardList(arr) {
      if (!Array.isArray(arr)) return [];
      return arr.map(function (it) {
        if (!isObj(it) || !it.id || !it.title) return null;
        return {
          vod_id: str(it.id),
          vod_name: str(it.title),
          vod_pic: safePic(it.cover_url),
          vod_remarks: str(it.teller || '')
        };
      }).filter(Boolean);
    }

    function ensureYtPlayHosts() {
      if (ytApiHosts.length) return;
      var headUrls = [cfg.headUrl1, cfg.headUrl2].filter(Boolean);
      for (var i = 0; i < headUrls.length; i++) {
        try {
          var r = req(headUrls[i], { timeout: 4000, buffer: 2, headers: { 'User-Agent': cfg.browserUa } });
          if (r && r.code === 200 && typeof r.content === 'string') {
            var b = b64ToBytes(r.content);
            if (b.length > 64 && ((b.length - 48) % 16) === 0) {
              var ct = b.subarray(0, b.length - 48);
              var k = b.subarray(b.length - 48, b.length - 16);
              var iv = b.subarray(b.length - 16);
              var dec = nodeCipher('decrypt', 'aes-256-cbc', bytesToB64(k), bytesToB64(iv), bytesToB64(ct), '');
              var outer = JSON.parse(b64ToUtf8(dec.data));
              var inner = outer && outer.signed_payload ? JSON.parse(b64ToUtf8(outer.signed_payload)) : outer;
              if (inner && Array.isArray(inner.api_hosts)) {
                inner.api_hosts.forEach(function (h) {
                  if (typeof h === 'string' && /^https:\/\//i.test(h)) ytApiHosts.push(h.replace(/\/+$/, ''));
                });
                if (ytApiHosts.length) break;
              }
            }
          }
        } catch (_) {}
      }
      if (!ytApiHosts.length) ytApiHosts = [cfg.fallbackApi1, cfg.fallbackApi2].filter(Boolean);
    }

    __drpy.home = function () {
      var filters = {};
      try { filters = JSON.parse(cfg.filtersJson); } catch (_) {}
      return {
        class: [
          { type_id: '2', type_name: '小说' },
          { type_id: '1', type_name: '评书' }
        ],
        filters: filters
      };
    };
    __drpy.homeVod = function () { return __drpy.category('2', 1, true, {}); };
    __drpy.category = function (tid, pg, filter, extend) {
      var page = Math.max(1, Number(pg) || 1);
      var cls = str((extend && (extend.class || extend.cateId)) || '').trim();
      var path = cls
        ? ('/categories/' + encodeURIComponent(cls) + '/comprehensive/p' + page)
        : ('/types/' + encodeURIComponent(str(tid)) + '/comprehensive/p' + page);
      var d = ytGetJson(cfg.jsonBase + path);
      var list = ytCardList(isObj(d) ? d.data : []);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: 999, list: list };
    };
    __drpy.search = function (wd, quick, pg) {
      var page = Math.max(1, Number(pg) || 1);
      var kw = str(wd).trim();
      if (!kw) return { page: 1, pagecount: 1, limit: 20, total: 0, list: [] };
      var encPayload = ytEncryptGcm(JSON.stringify({ keyword: kw, page: page }));
      var r = httpReq(cfg.searchUrl, {
        method: 'POST',
        headers: { 'User-Agent': cfg.apiUa, 'Content-Type': 'application/json' },
        body: JSON.stringify({ payload: encPayload })
      });
      if (r.code < 200 || r.code >= 300) fail();
      var outer = JSON.parse(r.content);
      var d = outer && outer.payload ? ytDecryptPayload(outer.payload) : outer;
      var list = ytCardList(isObj(d) ? d.results : []);
      return { page: page, pagecount: list.length >= 20 ? page + 1 : page, limit: 20, total: list.length, list: list };
    };
    __drpy.detail = function (id) {
      var aid = str(id).trim();
      var info = ytGetJson(cfg.albumInfoUrl + encodeURIComponent(aid));
      var chData = ytGetJson(cfg.albumChaptersUrl + encodeURIComponent(aid));
      var chapters = isObj(chData) && Array.isArray(chData.chapters) ? chData.chapters : [];
      var eps = chapters.map(function (ch, idx) {
        if (!isObj(ch)) return '';
        var cIdx = ch.index !== undefined ? str(ch.index) : String(idx + 1);
        return str(ch.title || ('第' + (idx + 1) + '集')).replace(/[$#]/g, ' ') + '$' + aid + '|||' + cIdx;
      }).filter(Boolean);
      return {
        list: [{
          vod_id: aid,
          vod_name: str(isObj(info) && info.title || aid),
          vod_pic: safePic(isObj(info) ? info.cover_url : ''),
          type_name: str(isObj(info) ? info.cat : ''),
          vod_actor: str(isObj(info) ? info.teller : ''),
          vod_director: str(isObj(info) ? info.author : ''),
          vod_content: stripHtml(isObj(info) ? (info.intro || info.desc || info.title) : ''),
          vod_play_from: eps.length ? '听听' : '',
          vod_play_url: eps.join('#')
        }]
      };
    };
    __drpy.play = function (flag, id) {
      ensureYtPlayHosts();
      var sp = str(id).split('|||');
      if (sp.length < 2) fail('drpy_invalid_id');
      var bodyStr = JSON.stringify({ album_id: sp[0], chapter_idx: parseInt(sp[1], 10) || 1 });
      for (var i = 0; i < ytApiHosts.length; i++) {
        try {
          var r = req(ytApiHosts[i] + '/h5/listening/play', {
            method: 'POST',
            timeout: 8000,
            headers: {
              'User-Agent': cfg.browserUa,
              'Content-Type': 'application/json',
              Origin: cfg.origin,
              Referer: cfg.referer,
              'X-Listening-Session': ytSession,
              'X-Listening-Timezone': 'Asia/Shanghai'
            },
            body: bodyStr
          });
          if (r && r.code >= 200 && r.code < 300 && typeof r.content === 'string') {
            var doc = JSON.parse(r.content);
            var inner = doc && doc.payload ? ytDecryptPayload(doc.payload) : doc;
            var pu = str(isObj(inner) ? (inner.play_url || (isObj(inner.data) ? inner.data.play_url : '')) : '').trim();
            if (pu) return { parse: 0, url: address(pu).url, header: { 'User-Agent': cfg.browserUa, Referer: cfg.referer } };
          }
        } catch (_) {}
      }
      fail('drpy_media_unresolved');
    };
    return;
  }

  fail('drpy_source_unavailable');
}

module.exports = function ftyLiveRule(config) {
  if (!config || !LIVE_ADAPTERS.includes(config.adapter) || !/^https?:\/\//.test(config.origin)) {
    throw Error('endpoint configuration required');
  }
  return 'var cfg=' + JSON.stringify(config) + ';\nvar rule={title:' + JSON.stringify(config.adapter) + ',host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:1,timeout:10000,预处理:"js:rule._install();",_install:' + installFtyLive.toString() + '};';
};

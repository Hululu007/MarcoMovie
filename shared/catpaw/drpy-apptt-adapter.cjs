// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
const { normalizeConfig } = require('./drpy-apptt-extractor.cjs');

function installAppTT() {
  var parseMap = Object.create(null);
  var allowedPaths = [
    '/v3/type/top_type',
    '/v3/type/tj_vod',
    '/v3/home/type_search',
    '/v3/home/vod_details',
    '/v3/home/search'
  ];
  function fail(code) { unsupportedFeature(code || 'drpy_source_unavailable'); }
  function object(v) { return v && typeof v === 'object' && !Array.isArray(v); }
  function text(v) { return v === undefined || v === null ? '' : String(v); }
  function address(value, base) {
    if (typeof value !== 'string' || !value || value.length > 8192 || /[\x00-\x20\x7f\\]/.test(value)) fail('drpy_media_protocol');
    var url; try { url = joinUrl(base || cfg.origin + '/', value); } catch (_) { fail('drpy_media_protocol'); }
    var match = /^(https?):\/\/([^/?#@]+)([^#]*)$/i.exec(url);
    if (!match) fail('drpy_media_protocol');
    return { url: url, origin: match[1].toLowerCase() + '://' + match[2].toLowerCase() };
  }
  function safePicture(primary, fallback) {
    var candidate = text(primary).trim() || text(fallback).trim();
    if (!candidate) return '';
    try {
      var url = joinUrl(cfg.origin + '/', candidate);
      return /^https?:\/\/[^/?#@]+(?:[/?#]|$)/i.test(url) && !/[\x00-\x20\x7f\\]/.test(url) ? url : '';
    } catch (_) { return ''; }
  }
  function checkChallenge(body) {
    if (/(?:SafeLineChallenge|__cdn_pow|Checking your browser|系统安全验证|正在验证您的浏览器|人机验证|verify you are human)/i.test(body) ||
        /<input[^>]+(?:name|id)=["']?(?:verify|validate|captcha)/i.test(body)) {
      fail('drpy_verification_required');
    }
  }
  function post(path, params) {
    if (allowedPaths.indexOf(path) < 0) fail('drpy_source_response');
    var stamp = String(Math.floor(Date.now() / 1000));
    var sign = CryptoJS.MD5(cfg.signKey + stamp).toString();
    var fields = Object.assign({ sign: sign, timestamp: stamp }, params || {});
    var boundary = '----MarcoAppTTBoundary7MA4YWxkTrZu0gW';
    var parts = [];
    Object.keys(fields).forEach(function (k) {
      parts.push('--' + boundary + '\r\nContent-Disposition: form-data; name="' + k + '"\r\n\r\n' + text(fields[k]) + '\r\n');
    });
    parts.push('--' + boundary + '--\r\n');
    var response;
    try {
      response = req(cfg.api + path, {
        method: 'POST',
        body: parts.join(''),
        headers: {
          'User-Agent': cfg.userAgent,
          'Content-Type': 'multipart/form-data; boundary=' + boundary,
          Accept: 'application/json,*/*'
        },
        redirect: 0,
        timeout: 10000
      });
    } catch (e) { fail(/^drpy_[a-z_]+$/.test(e && e.message) ? e.message : 'drpy_source_unavailable'); }
    var body = response && response.content;
    if (typeof body !== 'string') fail();
    checkChallenge(body);
    if (response.code < 200 || response.code >= 300) fail();
    var doc; try { doc = JSON.parse(body); } catch (_) { fail('drpy_source_response'); }
    if (!object(doc) || (Object.prototype.hasOwnProperty.call(doc, 'code') && ![1, 200, '1', '200', true].includes(doc.code))) {
      fail();
    }
    if (!object(doc.data)) fail('drpy_source_response');
    return doc.data;
  }
  function card(item) {
    if (!object(item) || item.vod_id === undefined || item.vod_id === null || !text(item.vod_name).trim()) return null;
    return {
      vod_id: text(item.vod_id).trim(),
      vod_name: text(item.vod_name).trim(),
      vod_pic: safePicture(item.vod_pic, item.vod_pic_thumb),
      vod_remarks: text(item.vod_remarks).trim()
    };
  }
  __drpy.home = function () {
    var data = post('/v3/type/top_type', {});
    if (!Array.isArray(data.list)) fail('drpy_source_response');
    var classes = [];
    data.list.forEach(function (item) {
      if (!object(item) || item.type_id === undefined || !text(item.type_name).trim()) return;
      classes.push({ type_id: text(item.type_id).trim(), type_name: text(item.type_name).trim() });
    });
    return { class: classes, filters: {} };
  };
  __drpy.homeVod = function () {
    var data = post('/v3/type/tj_vod', {});
    if (!Array.isArray(data.type_vod)) fail('drpy_source_response');
    var result = [], seen = Object.create(null);
    data.type_vod.forEach(function (group) {
      if (!object(group) || !Array.isArray(group.vod)) return;
      group.vod.forEach(function (row) {
        var c = card(row);
        if (c && !seen[c.vod_id]) { seen[c.vod_id] = true; result.push(c); }
      });
    });
    return { list: result };
  };
  __drpy.category = function (id, pg, filter, extend) {
    Object.keys(extend || {}).forEach(function (key) {
      var v = extend[key];
      if (v !== undefined && v !== null && text(v).trim() !== '' && text(v).trim() !== '全部') {
        fail('drpy_filter_not_supported');
      }
    });
    var pageNum = Math.max(1, Number(pg) || 1);
    var data = post('/v3/home/type_search', { type_id: text(id), limit: '12', page: String(pageNum) });
    if (!Array.isArray(data.list)) fail('drpy_source_response');
    var values = [];
    data.list.forEach(function (row) {
      var c = card(row);
      if (c) values.push(c);
    });
    var last = Number.isInteger(data.pagecount) && data.pagecount > 0
      ? data.pagecount
      : (values.length < 12 ? pageNum : pageNum + 1);
    var total = Number.isInteger(data.total) && data.total >= 0 ? data.total : last * 12;
    return { page: pageNum, pagecount: last, limit: 12, total: total, list: values };
  };
  __drpy.search = function (word, quick, pg) {
    var pageNum = Math.max(1, Number(pg) || 1);
    if (pageNum >= 2) return { page: pageNum, pagecount: 1, limit: 0, total: 0, list: [] };
    var kw = text(word).trim();
    if (!kw) return { page: 1, pagecount: 1, limit: 0, total: 0, list: [] };
    var data = post('/v3/home/search', { keyword: kw });
    if (!Array.isArray(data.list)) fail('drpy_source_response');
    var values = [];
    data.list.forEach(function (row) {
      var c = card(row);
      if (c && c.vod_name.indexOf(kw) >= 0) values.push(c);
    });
    return { page: 1, pagecount: 1, limit: values.length, total: values.length, list: values };
  };
  __drpy.detail = function (id) {
    var vodId = text(id).split(',')[0].trim();
    if (!/^\d{1,20}$/.test(vodId)) fail('drpy_invalid_id');
    var data = post('/v3/home/vod_details', { vod_id: vodId });
    var content = text(data.vod_content || data.vod_blurb)
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/<[^>]+>/g, '').replace(/\\n/g, ' ').trim();
    var playList = Array.isArray(data.vod_play_list) ? data.vod_play_list : [];
    var fromNames = [], urlGroups = [];
    parseMap = Object.create(null);
    playList.forEach(function (line, idx) {
      if (!object(line) || !Array.isArray(line.urls)) return;
      var flag = text(line.flag || line.name || line.title || ('线路' + (idx + 1))).trim();
      if (!flag) return;
      var episodes = [];
      line.urls.forEach(function (ep, epIdx) {
        if (!object(ep) || !text(ep.url).trim()) return;
        var epName = text(ep.name || ('第' + (epIdx + 1) + '集')).replace(/[$#]/g, ' ').trim();
        episodes.push((epName || ('第' + (epIdx + 1) + '集')) + '$' + text(ep.url).trim());
      });
      if (!episodes.length) return;
      if (Array.isArray(line.parse_urls)) {
        for (var i = 0; i < line.parse_urls.length; i++) {
          var p = text(line.parse_urls[i]).trim();
          if (p && p !== 'null' && /^https?:\/\//i.test(p) && !/[\x00-\x20\x7f\\]/.test(p)) {
            try { parseMap[flag] = address(p).url; break; } catch (_) { globalThis.__drpyUnsupported = null; }
          }
        }
      }
      fromNames.push(flag);
      urlGroups.push(episodes.join('#'));
    });
    return {
      list: [{
        vod_id: text(data.vod_id || vodId).trim(),
        vod_name: text(data.vod_name).trim() || vodId,
        vod_pic: safePicture(data.vod_pic, data.vod_pic_thumb),
        vod_year: text(data.vod_year).trim(),
        vod_area: text(data.vod_area).trim(),
        vod_remarks: text(data.vod_remarks).trim(),
        vod_actor: text(data.vod_actor).trim(),
        vod_director: text(data.vod_director).trim(),
        vod_content: content,
        vod_play_from: fromNames.join('$$$'),
        vod_play_url: urlGroups.join('$$$')
      }]
    };
  };
  __drpy.play = function (flag, id) {
    var raw = text(id).trim();
    if (!raw) fail('drpy_media_unresolved');
    var parser = parseMap[text(flag)];
    if (parser && !/\.(?:m3u8|mp4)(?:[?#]|$)/i.test(raw)) {
      var target = address(parser + raw).url;
      var response;
      try {
        response = req(target, {
          headers: { 'User-Agent': cfg.userAgent, Accept: 'application/json,*/*' },
          redirect: 0,
          timeout: 10000
        });
      } catch (_) { fail('drpy_media_unresolved'); }
      if (!response || response.code < 200 || response.code >= 300 || typeof response.content !== 'string') {
        fail('drpy_media_unresolved');
      }
      checkChallenge(response.content);
      var parsed; try { parsed = JSON.parse(response.content); } catch (_) { fail('drpy_media_unresolved'); }
      var candidate = text((object(parsed.data) ? parsed.data.url : '') || parsed.url).trim();
      if (!candidate || candidate === 'null') fail('drpy_media_unresolved');
      return { parse: 0, url: address(candidate).url, header: { 'User-Agent': cfg.userAgent } };
    }
    return { parse: 0, url: address(raw).url, header: { 'User-Agent': cfg.userAgent } };
  };
}

module.exports = function appttRule(config) {
  const cfg = normalizeConfig(config);
  return 'var cfg=' + JSON.stringify(cfg) + ';\nvar rule={title:"AppTT",host:cfg.origin,homeUrl:"/",searchable:2,quickSearch:1,filterable:0,timeout:10000,预处理:"js:rule._install();",_install:' + installAppTT.toString() + '};';
};

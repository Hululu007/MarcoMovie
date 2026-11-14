// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// The imported plugin is data only: never evaluate its Python, DEX or native code.
const crypto = require('node:crypto');
const {zipMember, unwrapGuard, Dex, readFtyGuardArtifact, MAX} = require('./drpy-guard-extractor.cjs');
const ARTIFACTS = {
  '88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204': '141dd6387f9c0334c070c12663b48281153e7e4a3138b423dbadb55aeb9c8247',
  'e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e': 'f68c170d1f12077550eb3ec912e7ae004a57624f314db0e6280a2b1cc319ba5c',
  'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': '7ae99a034ee2616f0b850ab0c1610d5d4d45d627677fa3e41c8e9809bd4b2a8d',
  '6f88b2001d45018aad4e7293566ef739be92dee85c123db4cc062539973fe799': {
    init: 'e629255d03ab57c08e19d4e31d2a6264b1da02b900c797f54338ff6c2ce814f6',
    headersMethod: 'KJ',
    headers: '9eb3be5e8f254353e700b019f1418b15867568bd2df76537140bd122616c0480',
    resolveMethod: 'Gd',
    resolve: '39424b69961d6d618255a96b86823dae6bb41f2e9ac7be40889a7c7a143ff550'
  }
};
const PYTHON = 'cb2ac6239c973bd105be36643d68b1e72d6b8e8c85f29dd8b2428685a4b9de89';
const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
function endpoint(value) {
  if (typeof value !== 'string' || !value || value.length > 2048 || /[\s\x00-\x1f\x7f\\]/.test(value)) fail();
  let url; try { url = new URL(value); } catch (_) { fail(); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail();
  return url;
}
function normalizeConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config) ||
      Object.keys(config).sort().join(',') !== 'origin,parserMap,parsers,userAgent') fail();
  const origin = endpoint(config.origin);
  if (origin.pathname !== '/' || origin.search || typeof config.userAgent !== 'string' ||
      !config.userAgent || config.userAgent.length > 512 || /[\r\n\0]/.test(config.userAgent)) fail();
  if (!Array.isArray(config.parsers) || config.parsers.length !== 2 ||
      !config.parserMap || typeof config.parserMap !== 'object' || Array.isArray(config.parserMap)) fail();
  const keys = ['co', 'BBA', 'vwnet', 'YYNB', 'JD4K', 'JD2K', 'qiyi', 'bilibili', 'qq', 'youku'];
  if (Object.keys(config.parserMap).sort().join(',') !== keys.sort().join(',')) fail();
  const parser = value => {
    const url = endpoint(value);
    if (url.pathname !== '/player/mplayer.php' || url.search) fail();
    return url.href;
  };
  return {origin:origin.origin, userAgent:config.userAgent,
    parsers:config.parsers.map(parser),
    parserMap:Object.fromEntries(keys.map(key => [key, parser(config.parserMap[key])]))};
}
function extractFy(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  const profile = ARTIFACTS[sha(bytes)];
  const budget = {bytes:0, entries:0};
  const cls = 'Lcom/github/catvod/spider/Fy;';
  let dex;
  if (!profile) {
    try {
      ({reader: dex} = readFtyGuardArtifact(bytes, true));
    } catch (error) {
      if (error && error.message === 'invalid_artifact') fail();
      throw error;
    }
    const methods = dex.classMethods(cls);
    if (!methods) throw Error('guard_artifact_unsupported');
    let origin, userAgent, tag4k, defaultParser, jdParser, tag2k;
    try {
      const initLits = dex.extractMethodLiterals(cls, 'init');
      if (!initLits || initLits.length !== 1) fail();
      origin = initLits[0].atUnit.get(0);
      if (typeof origin !== 'string' || !/^https?:\/\//i.test(origin)) {
        const cands = initLits[0].list.filter(x => /^https?:\/\/[^/?#]+\/?$/i.test(x.value));
        if (cands.length !== 1) fail();
        origin = cands[0].value;
      }
      const headerMethods = methods.filter(m => m.sig === 'Ljava/util/Map;()');
      let uaVal = null;
      for (const hm of headerMethods) {
        const lits = dex.extractMethodLiterals(cls, hm.name)?.find(x => x.sig === hm.sig && x.size === hm.size);
        if (!lits) continue;
        if (hm.name === 'KJ' && lits.atUnit.get(5) === 'User-Agent' && lits.atUnit.has(7)) {
          uaVal = lits.atUnit.get(7);
          break;
        }
        const idx = lits.list.findIndex(x => x.value === 'User-Agent');
        if (idx >= 0 && idx + 1 < lits.list.length) {
          uaVal = lits.list[idx + 1].value;
          break;
        }
      }
      if (!uaVal) fail();
      userAgent = uaVal;

      const resolveLits = dex.extractMethodLiterals(cls, 'Gd') || [];
      const gd = resolveLits.find(l => l.atUnit.get(195) === 'JD4K' && l.atUnit.get(207) === 'JD2K' && l.atUnit.has(201) && l.atUnit.has(203));
      if (gd) {
        tag4k = gd.atUnit.get(195);
        defaultParser = endpoint(gd.atUnit.get(201)).origin + '/player/mplayer.php';
        jdParser = endpoint(gd.atUnit.get(203)).origin + '/player/mplayer.php';
        tag2k = gd.atUnit.get(207);
      } else {
        let found = null;
        for (const m of methods) {
          if (m.sig !== 'Ljava/lang/String;(Ljava/lang/String;Ljava/lang/String;Ljava/util/List;)') continue;
          const ml = dex.extractMethodLiterals(cls, m.name)?.find(x => x.size === m.size);
          if (!ml) continue;
          const i4k = ml.list.findIndex(x => x.value === 'JD4K');
          const i2k = ml.list.findIndex(x => x.value === 'JD2K');
          if (i4k >= 0 && i2k > i4k) {
            const urls = ml.list.slice(i4k, i2k + 1).filter(x => /^https?:\/\/[^?#]+\/player\/mplayer\.php$/i.test(x.value));
            if (urls.length === 2) {
              found = ['JD4K', endpoint(urls[0].value).origin + '/player/mplayer.php', endpoint(urls[1].value).origin + '/player/mplayer.php', 'JD2K'];
              break;
            }
          }
        }
        if (!found) fail();
        [tag4k, defaultParser, jdParser, tag2k] = found;
      }
    } catch (error) {
      if (error && error.message === 'invalid_artifact') fail();
      throw error;
    }
    if (tag4k !== 'JD4K' || tag2k !== 'JD2K') fail();
    const parserMap = Object.create(null);
    for (const key of ['co', 'BBA', 'vwnet', 'YYNB', 'qiyi', 'bilibili', 'qq', 'youku']) parserMap[key] = defaultParser;
    parserMap.JD4K = jdParser;
    parserMap.JD2K = jdParser;
    return normalizeConfig({origin, userAgent, parserMap, parsers:[defaultParser, jdParser]});
  }
  try {
    dex = new Dex(zipMember(unwrapGuard(zipMember(bytes, 'assets/ftyshinidie.guard', budget)), 'classes.dex', budget));
  } catch (error) {
    if (error && error.message === 'invalid_artifact') fail();
    throw error;
  }
  if (typeof profile === 'object') {
    let origin, userAgent, tag4k, tag2k, defaultParser, jdParser;
    try {
      origin = dex.reviewedLiteralByHash(cls, 'init', profile.init, 0);
      userAgent = dex.reviewedLiteralByHash(cls, profile.headersMethod, profile.headers, 7);
      tag4k = dex.reviewedLiteralByHash(cls, profile.resolveMethod, profile.resolve, 195);
      defaultParser = endpoint(dex.reviewedLiteralByHash(cls, profile.resolveMethod, profile.resolve, 201)).origin + '/player/mplayer.php';
      jdParser = endpoint(dex.reviewedLiteralByHash(cls, profile.resolveMethod, profile.resolve, 203)).origin + '/player/mplayer.php';
      tag2k = dex.reviewedLiteralByHash(cls, profile.resolveMethod, profile.resolve, 207);
    } catch (error) {
      if (error && error.message === 'invalid_artifact') fail();
      throw error;
    }
    if (tag4k !== 'JD4K' || tag2k !== 'JD2K') fail();
    const parserMap = Object.create(null);
    for (const key of ['co', 'BBA', 'vwnet', 'YYNB', 'qiyi', 'bilibili', 'qq', 'youku']) parserMap[key] = defaultParser;
    parserMap.JD4K = jdParser;
    parserMap.JD2K = jdParser;
    return normalizeConfig({origin, userAgent, parserMap, parsers:[defaultParser, jdParser]});
  }
  const source = dex.reviewedLiteral(cls, 'init', profile, 7);
  if (sha(source) !== PYTHON) fail();
  // These exact literal shapes belong to the reviewed source hash above. Do not
  // generalize them into an evaluator or guess endpoints in an unknown version.
  const one = expression => { const matches = Array.from(source.matchAll(expression)); if (matches.length !== 1) fail(); return matches[0][1]; };
  const origin = one(/^        self\.host = "([^"\r\n]+)"$/gm);
  const userAgent = one(/^            "User-Agent": "([^"\r\n]+)",$/gm);
  const mapping = one(/^            player_config_map = \{([\s\S]*?)^            \}/gm);
  const parserMap = Object.create(null);
  const entries = Array.from(mapping.matchAll(/'([A-Za-z0-9]+)':\s*\('1',\s*'([^'\r\n]+)'\),/g));
  if (entries.length !== 10) fail();
  for (const [, key, value] of entries) {
    if (Object.prototype.hasOwnProperty.call(parserMap, key)) fail();
    parserMap[key] = endpoint(value).origin + '/player/mplayer.php';
  }
  const fallbacks = one(/^            all_apis = \[([\s\S]*?)^            \]/gm);
  const parsers = Array.from(fallbacks.matchAll(/'([^'\r\n]+)',/g), match => match[1]);
  return normalizeConfig({origin, userAgent, parserMap, parsers});
}
module.exports = {extractFy, normalizeConfig};

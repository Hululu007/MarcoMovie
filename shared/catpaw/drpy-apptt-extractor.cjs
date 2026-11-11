// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability: no native, DEX, or imported script execution.
const crypto = require('node:crypto');
const { zipMember, unwrapGuard, Dex, MAX } = require('./drpy-guard-extractor.cjs');
const { elfBytes, decodeShiftedExt } = require('./drpy-t4-extractor.cjs');

const PROFILES = {
  '88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204': {
    nativeSha: 'fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb',
    mask: 0xb7,
    methods: {
      '<init>': '297b351dfa02bd7dce8b68a809a285dd24a407220326672174f694d68cee8d3c',
      'yq': '6979c6a5f870a1ab1e8f864c11a4431f5008b8b65579a5195b352bf14f2a93a5'
    },
    clinit: '373a4dd60ed4235b57eb331c00fb804c71b3ed2cbf4cd8f44016fd24cbcff7fb',
    count: 726,
    ua: [0, 21, 2548],
    signKey: [73, 38, 3051]
  },
  'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': {
    nativeSha: 'd5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01',
    mask: 0x15,
    methods: {
      '<init>': '5693eba2ed2f7327f4b1f4c956753cbfd4302908208df2f8f951733dfd6a741b',
      'yq': '9112600e4100b4cd3875bbbeb0136b389f06585bc96f812581d9a1a293e12723'
    },
    clinit: '2d6c16ed470233a2957af5694681177a014d46367feb587c2e5648d354370872',
    count: 726,
    ua: [0, 21, 2088],
    signKey: [73, 38, 602]
  }
};

const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

function endpoint(value) {
  if (typeof value !== 'string' || !value || value.length > 2048 || /[\x00-\x20\x7f\\]/.test(value)) fail();
  let url; try { url = new URL(value); } catch (_) { fail(); }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) fail();
  return url;
}

function normalizeConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) fail();
  const keys = Object.keys(config).sort().join(',');
  if (keys !== 'api,signKey,userAgent' && keys !== 'api,origin,signKey,userAgent') fail();
  if (typeof config.api !== 'string') fail();
  const api = endpoint(config.api.trim());
  if (config.origin !== undefined && config.origin !== api.origin) fail();
  const basePath = api.pathname.replace(/\/+$/, '');
  if (typeof config.signKey !== 'string' || !/^[\x21-\x7e]{8,128}$/.test(config.signKey)) fail();
  if (typeof config.userAgent !== 'string' || !config.userAgent || config.userAgent.length > 512 || /[\r\n\0]/.test(config.userAgent)) fail();
  return {
    origin: api.origin,
    api: api.origin + basePath,
    signKey: config.signKey,
    userAgent: config.userAgent
  };
}

function extractAppTT(bytes, ext) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  const profile = PROFILES[sha(bytes)];
  if (!profile) throw Error('guard_artifact_unsupported');
  const native = zipMember(bytes, 'assets/ftyguard_v8.so');
  if (native.length !== 102440 || sha(native) !== profile.nativeSha) throw Error('guard_artifact_integrity');
  const key = elfBytes(native, 0x19198, 13).map(value => value ^ profile.mask);
  const api = decodeShiftedExt(ext, key).trim();
  const budget = { bytes: 0, entries: 0 };
  const dex = new Dex(zipMember(unwrapGuard(zipMember(bytes, 'assets/ftyshinidie.guard', budget)), 'classes.dex', budget));
  const className = 'Lcom/github/catvod/spider/AppTT;';
  for (const [method, expectedHash] of Object.entries(profile.methods)) {
    dex.reviewedCode(className, method, expectedHash);
  }
  const values = dex.reviewedShortArray(className, profile.clinit, 'short', 10, profile.count);
  const decode = ([start, length, mask]) => String.fromCharCode(...values.slice(start, start + length).map(v => v ^ mask));
  return normalizeConfig({
    api,
    signKey: decode(profile.signKey),
    userAgent: decode(profile.ua)
  });
}

module.exports = { extractAppTT, normalizeConfig };

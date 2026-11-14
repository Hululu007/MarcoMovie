// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability: no native, DEX, or imported script execution.
const crypto = require('node:crypto');
const { zipMember, unwrapGuard, Dex, readFtyGuardArtifact, MAX } = require('./drpy-guard-extractor.cjs');
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
  'e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e': {
    nativeSha: 'fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb',
    mask: 0xb7,
    methods: {
      '<init>': 'd491883dce8e8bdbcede7dae9731e25dc4e1c75568b1a7241d5dc2a9d83afaf6',
      'yq': 'da0daf12bc489a7ff502c0022b30353bceb9d2327f5416faa13887a271e2b24b'
    },
    clinit: 'd3a5b53dc5e0400c08c0d3f8b3b34fb9f5e4bc5ac8d45bc2356a245c01244476',
    count: 726,
    ua: [0, 21, 2843],
    signKey: [73, 38, 900]
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
  },
  '6f88b2001d45018aad4e7293566ef739be92dee85c123db4cc062539973fe799': {
    nativeSha: 'd5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01',
    mask: 0x15,
    methods: {
      '<init>': '3f970906b7eb4f2deceecd714b7ad044946a9700fb1e5c8bfe2c419c36ce3767',
      'yq': '6779524e53241c77dda4ef5613c95317eb774a3b9773c71ffafa0e45233b36a6'
    },
    clinit: 'b10c18a67e0e922902a05e0d2783ca1a29a3f833786f838a7541a6979d43af8d',
    count: 726,
    ua: [0, 21, 2168],
    signKey: [73, 38, 2271]
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
  const className = 'Lcom/github/catvod/spider/AppTT;';
  let native, mask, dex, signKey, userAgent;
  if (profile) {
    native = zipMember(bytes, 'assets/ftyguard_v8.so');
    if (native.length !== 102440 || sha(native) !== profile.nativeSha) throw Error('guard_artifact_integrity');
    mask = profile.mask;
    const budget = { bytes: 0, entries: 0 };
    dex = new Dex(zipMember(unwrapGuard(zipMember(bytes, 'assets/ftyshinidie.guard', budget)), 'classes.dex', budget));
    for (const [method, expectedHash] of Object.entries(profile.methods)) {
      dex.reviewedCode(className, method, expectedHash);
    }
    const values = dex.reviewedShortArray(className, profile.clinit, 'short', 10, profile.count);
    const decode = ([start, length, m]) => String.fromCharCode(...values.slice(start, start + length).map(v => v ^ m));
    signKey = decode(profile.signKey);
    userAgent = decode(profile.ua);
  } else {
    try {
      ({ native, mask, reader: dex } = readFtyGuardArtifact(bytes, true));
    } catch (error) {
      if (error && error.message === 'invalid_artifact') fail();
      throw error;
    }
    const info = dex.extractXorConstants(className);
    if (!info) throw Error('guard_artifact_unsupported');
    const uaMask = info.maskBySlice.get('0:21');
    const signMask = info.maskBySlice.get('73:38');
    if (uaMask === undefined || signMask === undefined) fail();
    const decode = (start, length, m) => String.fromCharCode(...info.values.slice(start, start + length).map(v => v ^ m));
    userAgent = decode(0, 21, uaMask);
    signKey = decode(73, 38, signMask);
  }
  const key = elfBytes(native, 0x19198, 13).map(value => value ^ mask);
  const api = decodeShiftedExt(ext, key).trim();
  return normalizeConfig({
    api,
    signKey,
    userAgent
  });
}

module.exports = { extractAppTT, normalizeConfig };

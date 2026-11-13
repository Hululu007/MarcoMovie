// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability reader. Never loads a JAR, DEX or native library.
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const MAX = 16 * 1024 * 1024;
const PROFILES = {
  // Desktop subscription captured on 2026-11-10. Read only the reviewed
  // constants; this artifact is distinct from the iOS subscription build.
  '88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204': {
    auete: {
      init: 'dacfe382fff4030441f2b81c37ba98fb5999cba25211b75851dee8b0a06245bc',
      player: '1217b0f480e8c7f0bcc1f8eac2168706ff85f0954ffe956cc399027785fd3c6f'
    },
    bttwoo: {
      init: 'b896ca9f25e8ea4cd786baf4b3ba84dadcb155f2659c5de1ed760179b06632cd',
      encodePlayKey: '450b78890c547603e2c633a10463959ded6f3764bef71c3733b21d8bb06a0a60',
      clinit: '0dedbc3c6c01b50c63f6e5032d08f2ff86e183efbbce52f64def41eb4a4b1d6e',
      headerClass: 'Lcom/github/catvod/spider/merge/x5;',
      headerClinit: '165116febeb25cc854103a354b005eb92f4a25dd766570abc6687a6ca6e11b25',
      headerCount: 1682,
      originMask: 2256,
      playKeyMask: 1841,
      userAgentMask: 2657
    },
    appgz: {
      methods: {
        '<init>': 'ab57f6f97defeef1829f2b0435ba2fdb47d364ba647d484318a973efbe4d4a87',
        'N': '560778016a320e768437d9cbc71847a818b442b78e2f8ba038ae423e6a5f615d',
        'tF': 'bf87fb15255e12f8e505009a98e262e15088e5dff093140366bb1be87ac9230b',
        'init': '83583414c8cc0f739ec5bd649ed9a1e339053d539a76f3cb96a38aceef88e707',
        'playerContent': 'dc332b898d7502a55ce37e87fa15f284d89958786aa9383d12e97cc20122c519'
      },
      clinit: '2c9dea916ed74561ca468d8a09d592e52863990f2a864798c13233dbf6fa3f6f',
      count: 3104,
      origin: [1206, 24, 959],
      privateKey: [16, 848, 2579],
      publicKey: [864, 216, 659],
      signatureSuffix: [1508, 36, 456],
      utdidKey: [1857, 44, 3141],
      ua: [1090, 13, 2926],
      version: [1110, 7, 429],
      pkg: [1128, 44, 848],
      ver: [1175, 7, 2409],
      code: [1193, 6, 1123]
    }
  },
  'e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e': {
    auete: {
      init: '3841e63ceeae29689e3b5d5b7f92b4d8177278dad5084818c2476df489128c17',
      player: '80e9d52800eae7b12c2278b2dd00e1d4677252d677e9185b594ef23ecd53b6b8'
    },
    bttwoo: {
      init: 'c47d9c1c569855288c1bf15c852120bb3c99c9bee1ccba4d9c8d93088f61094b',
      encodePlayKey: '5b7309680b6db8a307e62cb99b055d4130e71a278cbdf092c830542cad3cdb8e',
      clinit: 'b4511e08ff36b2c803be31a2dd8021f2a049fbabc587e805919e15b45ca7c284',
      headerClass: 'Lcom/github/catvod/spider/merge/ME;',
      headerClinit: '3dc0b269b870de31f4fdfa39e54778e8cc5d9cfb6d83c8903dd80e935ae1227e',
      originMask: 2303,
      playKeyMask: 3066,
      userAgentMask: 1121
    },
    appgz: {
      methods: {
        '<init>': 'e2ba5a4a37b1589bab71e7901d71d012f27e9c31230b39229752158d90907b4a',
        'N': '2cb95ba3ee3db3f7d155ae38bdd39d8b2d4173889c8a1ee090ad9f243d620942',
        'tF': 'b0a670647f413a02a78fc1629ae8bfe0b909da50978e7dc1d843f91f0e7a7210',
        'init': 'e03aceb447f2bf177f591f8faa58665755fa1e93788d04f1bfcee0f8ac56c9c3',
        'playerContent': '627d2eb2e82b2533258475479ed3757463116f4bf1283fe9f26da5bef49ee48a'
      },
      clinit: '73ceb72abb62d4326e733c8d9659e17aef072981e30718f346bf2f657bb83e6e',
      count: 3104,
      origin: [1206, 24, 2160],
      privateKey: [16, 848, 1726],
      publicKey: [864, 216, 1351],
      signatureSuffix: [1508, 36, 604],
      utdidKey: [1857, 44, 3163],
      ua: [1090, 13, 2573],
      version: [1110, 7, 2770],
      pkg: [1128, 44, 1606],
      ver: [1175, 7, 1803],
      code: [1193, 6, 2818]
    }
  },
  'da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096': {
    auete: {
      init: 'eb69d4f775b6daf51992de9cba679b08cbcc6cc74f41657cfc96abfd2e7c2e5d',
      player: '234fc41df99212edabdb8daf29729d1fb81b7299e885f1f135e76b2525542978'
    },
    bttwoo: {
      init: '29d4b86958e8938ae42d06b6ebea2f13ec7d7291f73b779f93d56dfa568c7f2d',
      encodePlayKey: '54d96ca7f290c72e10fb937c412947aeae700065e6b39ab848804d0aec68b210',
      clinit: '5e44de6d79539158b740b4bff09e870e337185a00108cb81eaa417fc4fc73c2d',
      headerClass: 'Lcom/github/catvod/spider/merge/py;',
      headerClinit: '4c3d41a2f28119ed234b8c07edbafcb68513e41bd38c2d738ec06accd7ff4fc0',
      originMask: 2525,
      playKeyMask: 814,
      userAgentMask: 1314
    },
    appgz: {
      methods: {
        '<init>': '69949e59be4c3b400c84667662d3ef2dec13ec7408fcad679c7b85c995b4f608',
        'N': 'ab20d133af30ac7d62e08689a2377d8b9f1c22959d1d16b0a307ca2bad8787b3',
        'tF': '3264180889d97e76e7c47568aee1d42fb13161225d89230e6f76305c96867029',
        'init': '470f47c3c9264cfee90a38c9c079b0d795a2f94a3cab46cdfb7524cc7f782cc9',
        'playerContent': '1327ab293c7aecadd64b07161252611eb3dd0b88344a298c00191afb10e04c70'
      },
      clinit: '72fff7eb333499f0008bda15435b3507a40362ed4ce0eea84e6311cc29b5a860',
      count: 3092,
      origin: [1221, 21, 1146],
      privateKey: [16, 848, 2169],
      publicKey: [864, 216, 2699],
      signatureSuffix: [1407, 36, 402],
      utdidKey: [1860, 44, 3174],
      ua: [1105, 13, 1843],
      version: [1125, 7, 2625],
      pkg: [1143, 44, 1861],
      ver: [1190, 7, 1200],
      code: [1208, 6, 2364]
    }
  },
  '6f88b2001d45018aad4e7293566ef739be92dee85c123db4cc062539973fe799': {
    auete: {
      init: '1ca0b0cb8382e382e0fcb3618ed6db3983480e15881dd162e0bc9da4d02e3136',
      player: '6d80cc0b70360c0af6995fd618632b184920b49a73556d7a46e358eb368139a5'
    },
    bttwoo: {
      init: '49ad4592d9aa5f747518891e297c82b357f7cd2ae0124f10b55472ec80f82a47',
      encodePlayKey: '82985609b8a2621de45855ab8430439170be33fb1ddd0f8ece76440c8231353d',
      clinit: '0e6ebb68799c497da9d287d322194ac2ee07fd3c964b64afdd109187274e68c1',
      headerClass: 'Lcom/github/catvod/spider/merge/g8;',
      headerClinit: '0646d6af48b53e6fbb7466b2b53245324f1a15e7e91b3992ef9825d6f0466613',
      headerCount: 1667,
      originMask: 1710,
      playKeyMask: 2905,
      userAgentMask: 1841
    },
    appgz: {
      methods: {
        '<init>': '83f2f88c9f2e8ebd393ab389cb81e13c979e528ab9682935c8a2db210a1aab45',
        'N': '1c8cde14d8d762efade0bbe69d4d4b836571e4bf4380c78331e6d0f0b85e1eb5',
        'tF': 'ebd346bd246c75ed73fd8f03d8ce64ce3b040fbcc947bc90a7d189e80d58f579',
        'init': 'bc71567abd955873c59b6ebbd4e2da7fc0bc731c7516480e5b861ddd8a6c5da3',
        'playerContent': '4d82600507d4042a158843a7362f7ee1916e689b789a37bad17ece35608c192b'
      },
      clinit: 'de7eafb4f831d7df2f8beb56986412461ae553a7914318e59b80d14813100649',
      count: 3085,
      origin: [1266, 21, 2403],
      privateKey: [16, 848, 2451],
      publicKey: [864, 216, 3222],
      signatureSuffix: [1452, 36, 2877],
      utdidKey: [1905, 44, 3129],
      ua: [1150, 13, 2667],
      version: [1170, 7, 2261],
      pkg: [1188, 44, 1577],
      ver: [1235, 7, 353],
      code: [1253, 6, 795]
    }
  }
};
const fail = () => { throw Error('invalid_artifact'); };
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const crcTable = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  crcTable[n] = c >>> 0;
}
function crc32(bytes) {
  let c = 0xffffffff;
  for (const byte of bytes) c = crcTable[(c ^ byte) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function adler32(bytes) {
  let a = 1, b = 0;
  for (let i = 0; i < bytes.length; i++) { a = (a + bytes[i]) % 65521; b = (b + a) % 65521; }
  return ((b << 16) | a) >>> 0;
}
function bounds(bytes, off, size) {
  if (!Number.isSafeInteger(off) || !Number.isSafeInteger(size) || off < 0 || size < 0 || off + size > bytes.length) fail();
}
function zipMember(bytes, target, budget = { bytes: 0, entries: 0 }) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX || bytes.length < 22) fail();
  let end = -1;
  for (let p = bytes.length - 22; p >= Math.max(0, bytes.length - 65557); p--) {
    if (bytes.readUInt32LE(p) === 0x06054b50 && p + 22 + bytes.readUInt16LE(p + 20) === bytes.length) { end = p; break; }
  }
  if (end < 0 || bytes.readUInt32LE(end + 4) !== 0) fail();
  const count = bytes.readUInt16LE(end + 10), centralSize = bytes.readUInt32LE(end + 12), central = bytes.readUInt32LE(end + 16);
  if (count !== bytes.readUInt16LE(end + 8) || !count || count > 512 || central + centralSize !== end) fail();
  if ((budget.entries += count) > 512) fail();
  let p = central, chosen;
  const names = new Set(), regions = [];
  for (let i = 0; i < count; i++) {
    bounds(bytes, p, 46);
    if (bytes.readUInt32LE(p) !== 0x02014b50) fail();
    const flags = bytes.readUInt16LE(p + 8), method = bytes.readUInt16LE(p + 10), crc = bytes.readUInt32LE(p + 16);
    const packed = bytes.readUInt32LE(p + 20), size = bytes.readUInt32LE(p + 24);
    const nameLength = bytes.readUInt16LE(p + 28), extra = bytes.readUInt16LE(p + 30), comment = bytes.readUInt16LE(p + 32);
    const local = bytes.readUInt32LE(p + 42);
    bounds(bytes, p + 46, nameLength + extra + comment);
    if (flags & ~0x0808 || ![0, 8].includes(method) || bytes.readUInt16LE(p + 34) || size > MAX || packed > MAX) fail();
    if ((budget.bytes += size) > 32 * 1024 * 1024) fail();
    const rawName = bytes.subarray(p + 46, p + 46 + nameLength);
    const name = rawName.toString('utf8');
    if (!name || !Buffer.from(name).equals(rawName) || name.includes('\\') || name.includes('\0') || name.startsWith('/') || name.split('/').some(s => s === '..' || s === '.')) fail();
    if (names.has(name)) fail();
    names.add(name);
    bounds(bytes, local, 30);
    if (local >= central || bytes.readUInt32LE(local) !== 0x04034b50 || bytes.readUInt16LE(local + 6) !== flags || bytes.readUInt16LE(local + 8) !== method) fail();
    const localName = bytes.readUInt16LE(local + 26), localExtra = bytes.readUInt16LE(local + 28), data = local + 30 + localName + localExtra;
    bounds(bytes, local + 30, localName + localExtra);
    if (!bytes.subarray(local + 30, local + 30 + localName).equals(rawName) || data + packed > central) fail();
    if (!(flags & 8) && (bytes.readUInt32LE(local + 14) !== crc || bytes.readUInt32LE(local + 18) !== packed || bytes.readUInt32LE(local + 22) !== size)) fail();
    let finish = data + packed;
    if (flags & 8) {
      bounds(bytes, finish, 12);
      if (bytes.readUInt32LE(finish) === 0x08074b50) finish += 4;
      bounds(bytes, finish, 12);
      if (bytes.readUInt32LE(finish) !== crc || bytes.readUInt32LE(finish + 4) !== packed || bytes.readUInt32LE(finish + 8) !== size) fail();
      finish += 12;
    }
    if (finish > central) fail();
    regions.push([local, finish]);
    if (name === target) chosen = { data, packed, size, method, crc };
    p += 46 + nameLength + extra + comment;
  }
  if (p !== end || !chosen) fail();
  regions.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < regions.length; i++) if (regions[i][0] < regions[i - 1][1]) fail();
  const c = chosen, input = bytes.subarray(c.data, c.data + c.packed);
  let output;
  try { output = c.method === 0 ? Buffer.from(input) : zlib.inflateRawSync(input, { maxOutputLength: Math.max(1, c.size) }); }
  catch (_) { fail(); }
  if (output.length !== c.size || crc32(output) !== c.crc) fail();
  return output;
}
function unwrapGuard(bytes) {
  const result = Buffer.from(bytes);
  for (let i = 0; i < result.length; i++) if ([1, 2, 5, 6].includes(result[i])) result[i] ^= 7;
  return result;
}
class Dex {
  constructor(bytes) {
    this.bytes = bytes;
    bounds(bytes, 0, 112);
    if (bytes.length > MAX || !bytes.subarray(0, 8).equals(Buffer.from('dex\n035\0')) || this.u32(32) !== bytes.length || this.u32(36) !== 112 || this.u32(40) !== 0x12345678) fail();
    if (!crypto.createHash('sha1').update(bytes.subarray(32)).digest().equals(bytes.subarray(12, 32)) || adler32(bytes.subarray(12)) !== this.u32(8)) fail();
    this.strings = this.table(56, 4).map(p => this.string(this.u32(p)));
    this.types = this.table(64, 4).map(p => this.at(this.strings, this.u32(p)));
    this.protos = this.table(72, 12).map(p => [this.at(this.types, this.u32(p + 4)), this.u32(p + 8)]);
    this.fields = this.table(80, 8).map(p => [this.at(this.types, this.u16(p)), this.at(this.types, this.u16(p + 2)), this.at(this.strings, this.u32(p + 4))]);
    this.methods = this.table(88, 8).map(p => [this.at(this.types, this.u16(p)), this.at(this.protos, this.u16(p + 2)), this.at(this.strings, this.u32(p + 4))]);
  }
  at(values, index) { if (!Number.isInteger(index) || index < 0 || index >= values.length) fail(); return values[index]; }
  u16(p) { bounds(this.bytes, p, 2); return this.bytes.readUInt16LE(p); }
  u32(p) { bounds(this.bytes, p, 4); return this.bytes.readUInt32LE(p); }
  uleb(p) {
    let value = 0;
    for (let i = 0; i < 5; i++) {
      bounds(this.bytes, p + i, 1); const byte = this.bytes[p + i];
      if (i === 4 && byte > 15) fail();
      value += (byte & 127) * 2 ** (i * 7);
      if (!(byte & 128)) return [value, p + i + 1];
    }
    fail();
  }
  table(header, stride) {
    const count = this.u32(header), offset = this.u32(header + 4);
    if (count > 262144) fail();
    bounds(this.bytes, offset, count * stride);
    return Array.from({ length: count }, (_, i) => offset + i * stride);
  }
  string(p) {
    let length; [length, p] = this.uleb(p);
    if (length > 1024 * 1024) fail();
    const chars = [];
    while (chars.length < length) {
      bounds(this.bytes, p, 1); const first = this.bytes[p++];
      if (first >= 1 && first < 128) chars.push(first);
      else if ((first & 224) === 192) {
        bounds(this.bytes, p, 1); const next = this.bytes[p++];
        const value = ((first & 31) << 6) | (next & 63);
        if ((next & 192) !== 128 || value < 128 && value !== 0) fail();
        chars.push(value);
      } else if ((first & 240) === 224) {
        bounds(this.bytes, p, 2); const a = this.bytes[p++], b = this.bytes[p++];
        const value = ((first & 15) << 12) | ((a & 63) << 6) | (b & 63);
        if ((a & 192) !== 128 || (b & 192) !== 128 || value < 2048) fail();
        chars.push(value);
      } else fail();
    }
    bounds(this.bytes, p, 1); if (this.bytes[p] !== 0) fail();
    let result = '';
    for (let i = 0; i < chars.length; i += 4096) result += String.fromCharCode(...chars.slice(i, i + 4096));
    return result;
  }
  reviewedCode(className, methodName, expectedHash) {
    const classes = this.table(96, 32).filter(p => this.at(this.types, this.u32(p)) === className);
    if (classes.length !== 1) fail();
    let p = this.u32(classes[0] + 24), counts = [], selected = null;
    if (!p) fail();
    for (let i = 0; i < 4; i++) { let n; [n, p] = this.uleb(p); if (n > 65536) fail(); counts.push(n); }
    for (let i = 0; i < counts[0] + counts[1]; i++) { [, p] = this.uleb(p); [, p] = this.uleb(p); }
    for (const count of counts.slice(2)) {
      let index = 0;
      for (let i = 0; i < count; i++) {
        let delta, code; [delta, p] = this.uleb(p); [, p] = this.uleb(p); [code, p] = this.uleb(p); index += delta;
        const [owner, , name] = this.at(this.methods, index);
        if (owner === className && name === methodName) { if (selected !== null || !code) fail(); selected = code; }
      }
    }
    if (selected === null) fail();
    const size = this.u32(selected + 12);
    if (!size || size > 65536) fail();
    bounds(this.bytes, selected, 16 + size * 2);
    if (sha(this.bytes.subarray(selected, selected + 16 + size * 2)) !== expectedHash) fail();
    return { offset: selected, size };
  }
  reviewedCodeByHash(className, methodName, expectedHash) {
    const classes = this.table(96, 32).filter(p => this.at(this.types, this.u32(p)) === className);
    if (classes.length !== 1) fail();
    let p = this.u32(classes[0] + 24), counts = [], selected = null;
    if (!p) fail();
    for (let i = 0; i < 4; i++) { let n; [n, p] = this.uleb(p); if (n > 65536) fail(); counts.push(n); }
    for (let i = 0; i < counts[0] + counts[1]; i++) { [, p] = this.uleb(p); [, p] = this.uleb(p); }
    for (const count of counts.slice(2)) {
      let index = 0;
      for (let i = 0; i < count; i++) {
        let delta, code; [delta, p] = this.uleb(p); [, p] = this.uleb(p); [code, p] = this.uleb(p); index += delta;
        const [owner, , name] = this.at(this.methods, index);
        if (owner === className && name === methodName && code) {
          const size = this.u32(code + 12);
          if (!size || size > 65536) fail();
          bounds(this.bytes, code, 16 + size * 2);
          if (sha(this.bytes.subarray(code, code + 16 + size * 2)) === expectedHash) {
            if (selected !== null) fail();
            selected = { offset: code, size };
          }
        }
      }
    }
    if (selected === null) fail();
    return selected;
  }
  reviewedLiteralByHash(className, methodName, expectedHash, unit) {
    const { offset: selected, size } = this.reviewedCodeByHash(className, methodName, expectedHash);
    if (!Number.isInteger(unit) || unit < 0 || unit + 1 >= size) fail();
    const instruction = selected + 16 + unit * 2, op = this.u16(instruction) & 255;
    if (op === 0x1a) return this.at(this.strings, this.u16(instruction + 2));
    if (op === 0x1b) {
      if (unit + 2 >= size) fail();
      return this.at(this.strings, this.u32(instruction + 2));
    }
    fail();
  }
  reviewedShortArray(className, expectedHash, fieldName, payloadUnit, count) {
    const { offset, size } = this.reviewedCode(className, '<clinit>', expectedHash);
    if (!Number.isInteger(payloadUnit) || payloadUnit < 10 || !Number.isInteger(count) || count < 1 || count > 4096 || payloadUnit + 4 + count > size || this.u16(offset + 2) !== 0) fail();
    const start = offset + 16;
    // The reviewed initializer starts by constructing v0:[S, filling it from a
    // literal payload, then storing v0 in this class's exact static short field.
    // Read those data bytes only; never evaluate any other initializer code.
    if (this.u16(start) !== 0x0013 || this.u16(start + 2) !== count || this.u16(start + 4) !== 0x0023 ||
        this.at(this.types, this.u16(start + 6)) !== '[S' || this.u16(start + 8) !== 0x0026 ||
        4 + this.u32(start + 10) !== payloadUnit || this.u16(start + 14) !== 0x0069) fail();
    const field = this.at(this.fields, this.u16(start + 16));
    if (field[0] !== className || field[1] !== '[S' || field[2] !== fieldName) fail();
    const payload = start + payloadUnit * 2;
    if (this.u16(payload) !== 0x0300 || this.u16(payload + 2) !== 2 || this.u32(payload + 4) !== count) fail();
    return Array.from({ length: count }, (_, i) => this.u16(payload + 8 + i * 2));
  }
  reviewedLiteral(className, methodName, expectedHash, unit, fieldName) {
    const { offset: selected, size } = this.reviewedCode(className, methodName, expectedHash);
    if (!Number.isInteger(unit) || unit < 0 || unit + 1 >= size) fail();
    // Exact reviewed code position, not an interpreter or a search for URL-like strings.
    const instruction = selected + 16 + unit * 2, word = this.u16(instruction);
    if ((word & 255) !== 0x1a) fail();
    if (fieldName) {
      if (unit + 3 >= size) fail();
      const write = this.u16(instruction + 4), field = this.at(this.fields, this.u16(instruction + 6));
      if ((write & 255) !== 0x5b || ((write >>> 8) & 15) !== word >>> 8 ||
          write >>> 12 !== this.u16(selected) - this.u16(selected + 2) ||
          field[0] !== className || field[1] !== 'Ljava/lang/String;' || field[2] !== fieldName) fail();
    }
    return this.at(this.strings, this.u16(instruction + 2));
  }
  literalFields(className) {
    const classes = this.table(96, 32).filter(p => this.at(this.types, this.u32(p)) === className);
    if (classes.length !== 1) fail();
    let p = this.u32(classes[0] + 24), count = [];
    if (!p) fail();
    for (let i = 0; i < 4; i++) { let value; [value, p] = this.uleb(p); if (value > 65536) fail(); count.push(value); }
    for (let i = 0; i < count[0] + count[1]; i++) { [, p] = this.uleb(p); [, p] = this.uleb(p); }
    let method = 0, code = null;
    for (let i = 0; i < count[2]; i++) {
      let delta, offset; [delta, p] = this.uleb(p); [, p] = this.uleb(p); [offset, p] = this.uleb(p); method += delta;
      const [owner, proto, name] = this.at(this.methods, method);
      if (owner === className && name === '<init>' && proto[0] === 'V' && proto[1] === 0) { if (code !== null) fail(); code = offset; }
    }
    if (!code) fail();
    const registers = this.u16(code), inputs = this.u16(code + 2), size = this.u32(code + 12);
    if (inputs !== 1 || this.u16(code + 6) || !size || size > 256) fail();
    bounds(this.bytes, code + 16, size * 2);
    const words = Array.from({ length: size }, (_, i) => this.u16(code + 16 + i * 2));
    if (words[size - 1] !== 0x000e) fail();
    const values = new Map(), fields = Object.create(null);
    let index = 0;
    while (index < size) {
      const word = words[index], op = word & 255;
      if (op === 0x70 && index === 0 && index + 2 < size) {
        const [owner, proto, name] = this.at(this.methods, words[index + 1]);
        if (!['Ljava/lang/Object;', 'Lcom/github/catvod/crawler/Spider;'].includes(owner) || name !== '<init>' || proto[0] !== 'V' || proto[1] !== 0 || word >>> 12 !== 1 || (words[index + 2] & 15) !== registers - 1) fail();
        index += 3;
      } else if ([0x1a, 0x1b].includes(op) && index + (op === 0x1b ? 2 : 1) < size) {
        const n = words[index + 1] + (op === 0x1b ? words[index + 2] * 65536 : 0);
        const register = word >>> 8;
        if (register >= registers) fail();
        values.set(register, this.at(this.strings, n)); index += op === 0x1b ? 3 : 2;
      } else if (op === 0x5b && index + 1 < size) {
        const source = (word >>> 8) & 15, object = word >>> 12;
        const [owner, type, name] = this.at(this.fields, words[index + 1]);
        if (owner !== className || type !== 'Ljava/lang/String;' || object !== registers - 1 || !values.has(source) || Object.hasOwn(fields, name)) fail();
        fields[name] = values.get(source); index += 2;
      } else if (word === 0x000e && index === size - 1) index++;
      else fail();
    }
    return fields;
  }
}
function extractKnownPlugin(bytes, adapter = 'dm84-v1') {
  if (!Buffer.isBuffer(bytes) || bytes.length > MAX) fail();
  const profile = PROFILES[sha(bytes)];
  if (!profile) throw Error('guard_artifact_unsupported');
  const budget = { bytes: 0, entries: 0 };
  const payload = zipMember(bytes, 'assets/ftyshinidie.guard', budget);
  const dex = zipMember(unwrapGuard(payload), 'classes.dex', budget);
  const reader = new Dex(dex);
  function endpoint(value) {
    if (typeof value !== 'string' || value.length > 2048) fail();
    let url; try { url = new URL(value); } catch (_) { fail(); }
    if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) fail();
    return url;
  }
  if (adapter === 'auete-v1') {
    const className = 'Lcom/github/catvod/spider/Auete;';
    const origin = endpoint(reader.reviewedLiteral(className, '<init>',
      profile.auete.init, 3, 'yq'));
    const mediaBase = endpoint(reader.reviewedLiteral(className, 'playerContent',
      profile.auete.player, 299));
    if (origin.pathname !== '/' || origin.search || mediaBase.search || !mediaBase.pathname.endsWith('/')) fail();
    return { origin: origin.origin, mediaBase: mediaBase.href,
      userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36' };
  }
  if (adapter === 'appgz-v1') {
    const className = 'Lcom/github/catvod/spider/Appgz;', g = profile.appgz;
    for (const [method, hash] of Object.entries(g.methods)) reader.reviewedCode(className, method, hash);
    const values = reader.reviewedShortArray(className, g.clinit, 'short', 38, g.count);
    const decode = ([start, length, mask]) => String.fromCharCode(...values.slice(start, start + length).map(value => value ^ mask));
    const origin = endpoint(decode(g.origin));
    if (origin.pathname !== '/' || origin.search) fail();
    const ver = decode(g.ver);
    const config = {origin:origin.origin,privateKey:decode(g.privateKey),publicKey:decode(g.publicKey),
      signatureSuffix:decode(g.signatureSuffix),utdidKey:decode(g.utdidKey),headers:{
        'User-Agent':decode(g.ua),'Version':decode(g.version),'PackageName':decode(g.pkg),
        'Ver':ver,'api-ver':ver,'code':decode(g.code)}};
    if (![config.privateKey,config.publicKey].every(v=>/^[A-Za-z0-9+/]+={0,2}$/.test(v)) ||
        Object.values(config.headers).some(v=>!v||/[\r\n\0]/.test(v))) fail();
    return config;
  }
  if (adapter === 'bttwoo-v1') {
    const className = 'Lcom/github/catvod/spider/Bttwoo;', b = profile.bttwoo;
    reader.reviewedCode(className, '<init>', b.init);
    reader.reviewedCode(className, 'encodePlayKey', b.encodePlayKey);
    const values = reader.reviewedShortArray(className, b.clinit, 'short', 10, 686);
    const headerValues = reader.reviewedShortArray(b.headerClass, b.headerClinit, 'short', 316, b.headerCount ?? 1667);
    const decode = (array, start, length, mask) => String.fromCharCode(...array.slice(start, start + length).map(value => value ^ mask));
    const origin = endpoint(decode(values, 0, 23, b.originMask)), playKey = decode(values, 24, 20, b.playKeyMask), userAgent = decode(headerValues, 1048, 117, b.userAgentMask);
    if (origin.pathname !== '/' || origin.search || !/^[\x21-\x7e]{20}$/.test(playKey) || /[\r\n]/.test(userAgent)) fail();
    return { origin: origin.href, playKey, userAgent };
  }
  if (adapter !== 'dm84-v1') fail();
  const fields = reader.literalFields('Lcom/github/catvod/spider/Dm84;');
  if (Object.keys(fields).length !== 2) fail();
  const origin = endpoint(fields.yq), parser = endpoint(fields.SN);
  if (origin.pathname !== '/' || origin.search) fail();
  return { origin: origin.origin, parser: parser.href, parserOrigin: parser.origin,
    userAgent: 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36' };
}
module.exports = { extractKnownPlugin, zipMember, unwrapGuard, Dex, crc32, adler32, MAX };

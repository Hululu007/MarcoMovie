export interface DynamicMethodCallLike {
  args?: unknown;
  argument?: (key: string) => unknown;
  hasArgument?: (key: string) => boolean;
}

export function extractMethodArg(call: unknown, key: string): unknown {
  if (call === null || call === undefined || typeof call !== 'object') {
    return undefined;
  }
  const typed = call as DynamicMethodCallLike;
  if (typeof typed.argument === 'function') {
    try {
      if (typeof typed.hasArgument === 'function' && !typed.hasArgument(key)) {
        // Fall through to raw args inspection in case a custom codec omits hasArgument.
      } else {
        const direct = typed.argument(key);
        if (direct !== undefined) {
          return direct;
        }
      }
    } catch (_err) {
      // Fall back to raw args inspection when call.args is null/primitive.
    }
  }
  const rawArgs = typed.args;
  if (rawArgs === null || rawArgs === undefined) {
    return undefined;
  }
  if (rawArgs instanceof Map) {
    return rawArgs.get(key);
  }
  if (typeof rawArgs === 'object') {
    return (rawArgs as Record<string, unknown>)[key];
  }
  return undefined;
}

export function recordFromDynamicObject(raw: unknown): Record<string, Object> {
  const out: Record<string, Object> = {};
  if (raw === null || raw === undefined) {
    return out;
  }
  if (raw instanceof Map) {
    raw.forEach((v: unknown, k: unknown) => {
      if (v !== undefined && v !== null) {
        out[String(k)] = v as Object;
      }
    });
    return out;
  }
  if (typeof raw === 'object') {
    const src = raw as Record<string, unknown>;
    const keys = Object.keys(src);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = src[k];
      if (v !== undefined && v !== null) {
        out[k] = v as Object;
      }
    }
  }
  return out;
}

export function stringRecordFromDynamicObject(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === null || raw === undefined) {
    return out;
  }
  if (raw instanceof Map) {
    raw.forEach((v: unknown, k: unknown) => {
      const key = String(k ?? '').trim();
      if (key.length > 0 && v !== undefined && v !== null) {
        out[key] = String(v);
      }
    });
    return out;
  }
  if (typeof raw === 'object') {
    const src = raw as Record<string, unknown>;
    const keys = Object.keys(src);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i].trim();
      const v = src[keys[i]];
      if (key.length > 0 && v !== undefined && v !== null) {
        out[key] = String(v);
      }
    }
  }
  return out;
}

export function stringArrayFromDynamicValue(raw: unknown): Array<string> {
  const list: Array<string> = [];
  if (Array.isArray(raw)) {
    for (let i = 0; i < raw.length; i++) {
      list.push(String(raw[i] ?? ''));
    }
  }
  return list;
}

export interface ChunkedAssetManifest {
  gen: string;
  count: number;
  totalBytes: number;
  checksum: string;
}

const CHUNKED_MANIFEST_PREFIX: string = '{"__mm_asset_chunks_v1__":1,';

export function computeFnv1aHex(bytes: Uint8Array): string {
  let h1: number = 0x811c9dc5;
  let h2: number = 0x9e3779b9;
  for (let i = 0; i < bytes.byteLength; i++) {
    const b: number = bytes[i];
    h1 ^= b;
    h1 = Math.imul(h1, 0x01000193) >>> 0;
    h2 ^= (b ^ ((i & 0xff) >>> 0));
    h2 = Math.imul(h2, 0x01000193) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

export function buildAssetAliasName(key: string): string {
  const base: string = 'marco_movie:' + key;
  if (base.length <= 160) {
    return base;
  }
  const encoded: Uint8Array = new Uint8Array(base.length);
  for (let i = 0; i < base.length; i++) {
    encoded[i] = base.charCodeAt(i) & 0xff;
  }
  return 'marco_movie:h_' + computeFnv1aHex(encoded) + '_' + key.substring(0, 64);
}

export function isChunkedManifestCandidate(text: string): boolean {
  return text.startsWith(CHUNKED_MANIFEST_PREFIX);
}

export function buildChunkedAssetManifestJson(
  gen: string,
  count: number,
  totalBytes: number,
  checksum: string
): string {
  return JSON.stringify({
    __mm_asset_chunks_v1__: 1,
    gen,
    count,
    totalBytes,
    checksum
  });
}

export function parseChunkedAssetManifest(text: string): ChunkedAssetManifest | null {
  if (!isChunkedManifestCandidate(text)) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return null;
    }
    const obj = parsed as Record<string, unknown>;
    if (obj['__mm_asset_chunks_v1__'] !== 1) {
      return null;
    }
    const gen = obj['gen'];
    const count = obj['count'];
    const totalBytes = obj['totalBytes'];
    const checksum = obj['checksum'];
    if (
      typeof gen !== 'string' ||
      gen.length === 0 ||
      typeof count !== 'number' ||
      !Number.isInteger(count) ||
      count <= 0 ||
      count > 128 ||
      typeof totalBytes !== 'number' ||
      !Number.isInteger(totalBytes) ||
      totalBytes <= 0 ||
      typeof checksum !== 'string' ||
      checksum.length !== 16
    ) {
      return null;
    }
    return { gen, count, totalBytes, checksum };
  } catch (_err) {
    return null;
  }
}

export function splitBytesIntoChunks(bytes: Uint8Array, maxChunkBytes: number): Array<Uint8Array> {
  const chunks: Array<Uint8Array> = [];
  const step: number = Math.max(1, Math.trunc(maxChunkBytes));
  for (let offset = 0; offset < bytes.byteLength; offset += step) {
    const end: number = Math.min(bytes.byteLength, offset + step);
    chunks.push(bytes.slice(offset, end));
  }
  return chunks;
}

export function concatByteChunks(chunks: Array<Uint8Array>): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    total += chunks[i].byteLength;
  }
  const merged: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    merged.set(chunks[i], offset);
    offset += chunks[i].byteLength;
  }
  return merged;
}

export function normalizeHeadersCaseInsensitive(raw: unknown): Record<string, string> {
  const rawRecord = stringRecordFromDynamicObject(raw);
  const keys = Object.keys(rawRecord);
  const seenLower = new Map<string, string>();
  const out: Record<string, string> = {};
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i].trim();
    const v = rawRecord[keys[i]].trim();
    if (k.length === 0 || v.length === 0) {
      continue;
    }
    const lower = k.toLowerCase();
    const prevKey = seenLower.get(lower);
    if (prevKey !== undefined && prevKey !== k) {
      delete out[prevKey];
    }
    seenLower.set(lower, k);
    out[k] = v;
  }
  return out;
}

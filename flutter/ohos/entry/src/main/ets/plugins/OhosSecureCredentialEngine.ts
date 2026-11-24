import type { ChunkedAssetManifest } from './OhosDynamicBridge';
import {
  buildAssetAliasName,
  buildChunkedAssetManifestJson,
  computeFnv1aHex,
  concatByteChunks,
  isChunkedManifestCandidate,
  parseChunkedAssetManifest,
  splitBytesIntoChunks
} from './OhosDynamicBridge';

export const ASSET_SECRET_DIRECT_MAX_BYTES: number = 960;
export const ASSET_CHUNK_BYTES: number = 960;
export const ASSET_MAX_CHUNKS: number = 64;

export interface OhosSecureStorageDeps {
  assetQueryBytes(alias: string): Promise<Uint8Array | null>;
  assetPutBytes(alias: string, secretBytes: Uint8Array): Promise<void>;
  assetRemoveAlias(alias: string): Promise<void>;
  readLegacyFallback(key: string): Promise<string | null>;
  deleteLegacyFallback(key: string): Promise<void>;
  readPendingDeleteMarker(markerKey: string): Promise<boolean>;
  writePendingDeleteMarker(markerKey: string): Promise<void>;
  clearPendingDeleteMarker(markerKey: string): Promise<void>;
  encodeUtf8(text: string): Uint8Array;
  decodeUtf8(bytes: Uint8Array): string;
}

export function buildPendingDeleteMarkerKey(key: string, encodeUtf8: (text: string) => Uint8Array): string {
  return 'del_' + computeFnv1aHex(encodeUtf8(key));
}

/**
 * Production HarmonyOS credential state machine used directly by `OhosSystemPlugin.ets`.
 *
 * Guarantees:
 * 1. New writes go exclusively to Asset Store (direct <=960B or generation-scoped chunked up to 64*960B)
 *    with mandatory read-back verification; never writes secrets into Preferences.
 * 2. Legacy fallback migration:
 *    - Asset Store empty + fallback has value -> write Asset Store, verify read-back match, THEN delete fallback.
 *    - Asset Store has A + fallback has same A -> interrupted migration residue; safe to delete fallback and return A.
 *    - Asset Store has A + fallback has DIFFERENT B -> cannot tell which is newer; preserve BOTH A and B without
 *      silently deleting B until an explicit write or delete resolves the conflict.
 * 3. Crash-safe resumable logout (`delete`):
 *    - Persist a non-secret pending-delete tombstone (`del_<hash>`) BEFORE removing credentials.
 *    - Delete legacy fallback and Asset Store (chunks + primary), verifying BOTH stores are empty before clearing
 *      the tombstone.
 *    - If logout is interrupted at any step, the next cold start (`read`) sees the tombstone and resumes deletion
 *      instead of resurrecting/re-migrating the pending-delete credential.
 */
export class OhosSecureCredentialEngine {
  private readonly deps: OhosSecureStorageDeps;
  private assetGenSeq: number = 0;

  constructor(deps: OhosSecureStorageDeps) {
    this.deps = deps;
  }

  private async bestEffortRemoveChunks(primaryAlias: string, gen: string, count: number): Promise<void> {
    for (let i = 0; i < count; i++) {
      try {
        await this.deps.assetRemoveAlias(primaryAlias + '#' + gen + '#' + String(i));
      } catch (_err) {
        // Best-effort orphan cleanup only; never mask primary outcome.
      }
    }
  }

  async readFromAssetStore(key: string): Promise<string | null> {
    const primaryAlias: string = buildAssetAliasName(key);
    const rawPrimary: Uint8Array | null = await this.deps.assetQueryBytes(primaryAlias);
    if (rawPrimary === null) {
      return null;
    }
    const decodedPrimary: string = this.deps.decodeUtf8(rawPrimary);
    const manifest: ChunkedAssetManifest | null = parseChunkedAssetManifest(decodedPrimary);
    if (manifest === null) {
      return decodedPrimary;
    }
    const chunks: Array<Uint8Array> = [];
    for (let i = 0; i < manifest.count; i++) {
      const chunkBytes: Uint8Array | null = await this.deps.assetQueryBytes(
        primaryAlias + '#' + manifest.gen + '#' + String(i)
      );
      if (chunkBytes === null) {
        throw new Error('系统安全存储分段凭据不完整，请重新保存');
      }
      chunks.push(chunkBytes);
    }
    const merged: Uint8Array = concatByteChunks(chunks);
    if (
      merged.byteLength !== manifest.totalBytes ||
      computeFnv1aHex(merged) !== manifest.checksum
    ) {
      throw new Error('系统安全存储分段凭据校验失败，请重新保存');
    }
    return this.deps.decodeUtf8(merged);
  }

  async writeToAssetStoreVerified(key: string, value: string): Promise<void> {
    const primaryAlias: string = buildAssetAliasName(key);
    const secretBytes: Uint8Array = this.deps.encodeUtf8(value);
    const existingRaw: Uint8Array | null = await this.deps.assetQueryBytes(primaryAlias);
    const oldManifest: ChunkedAssetManifest | null =
      existingRaw !== null ? parseChunkedAssetManifest(this.deps.decodeUtf8(existingRaw)) : null;

    let activeGen: string | null = null;
    if (
      secretBytes.byteLength <= ASSET_SECRET_DIRECT_MAX_BYTES &&
      !isChunkedManifestCandidate(value)
    ) {
      await this.deps.assetPutBytes(primaryAlias, secretBytes);
    } else {
      const chunks: Array<Uint8Array> = splitBytesIntoChunks(secretBytes, ASSET_CHUNK_BYTES);
      if (chunks.length > ASSET_MAX_CHUNKS) {
        throw new Error('凭据内容超出系统安全存储容量限制');
      }
      const checksum: string = computeFnv1aHex(secretBytes);
      let gen: string =
        Date.now().toString(36) + '_' + String(++this.assetGenSeq) + '_' + checksum.substring(0, 8);
      if (oldManifest !== null && oldManifest.gen === gen) {
        gen = gen + '_n' + String(++this.assetGenSeq);
      }
      activeGen = gen;
      let writtenCount: number = 0;
      try {
        for (let i = 0; i < chunks.length; i++) {
          await this.deps.assetPutBytes(primaryAlias + '#' + gen + '#' + String(i), chunks[i]);
          writtenCount = i + 1;
        }
        const manifestJson: string = buildChunkedAssetManifestJson(
          gen,
          chunks.length,
          secretBytes.byteLength,
          checksum
        );
        await this.deps.assetPutBytes(primaryAlias, this.deps.encodeUtf8(manifestJson));
      } catch (writeErr) {
        await this.bestEffortRemoveChunks(primaryAlias, gen, writtenCount);
        if (writeErr instanceof Error) {
          throw writeErr;
        }
        throw new Error(String(writeErr));
      }
    }

    const readBack: string | null = await this.readFromAssetStore(key);
    if (readBack !== value) {
      throw new Error('系统安全存储写入回读校验不一致，请重试');
    }

    if (oldManifest !== null && oldManifest.gen !== activeGen) {
      await this.bestEffortRemoveChunks(primaryAlias, oldManifest.gen, oldManifest.count);
    }
  }

  private async removeAssetEntryVerified(key: string): Promise<void> {
    const primaryAlias: string = buildAssetAliasName(key);
    const existingRaw: Uint8Array | null = await this.deps.assetQueryBytes(primaryAlias);
    const manifest: ChunkedAssetManifest | null =
      existingRaw !== null ? parseChunkedAssetManifest(this.deps.decodeUtf8(existingRaw)) : null;

    if (manifest !== null) {
      for (let i = 0; i < manifest.count; i++) {
        await this.deps.assetRemoveAlias(primaryAlias + '#' + manifest.gen + '#' + String(i));
      }
    }
    await this.deps.assetRemoveAlias(primaryAlias);

    const remaining: Uint8Array | null = await this.deps.assetQueryBytes(primaryAlias);
    if (remaining !== null) {
      throw new Error('系统安全存储凭据删除校验失败，请重试');
    }
  }

  async read(key: string): Promise<string | null> {
    if (key.length === 0) {
      return null;
    }
    const markerKey: string = buildPendingDeleteMarkerKey(key, this.deps.encodeUtf8);
    const pendingDelete: boolean = await this.deps.readPendingDeleteMarker(markerKey);
    if (pendingDelete) {
      // A previous logout was interrupted: resume and finish deletion instead of migrating/returning stale data.
      await this.delete(key);
      return null;
    }

    const protectedValue: string | null = await this.readFromAssetStore(key);
    const legacyValue: string | null = await this.deps.readLegacyFallback(key);

    if (protectedValue !== null) {
      if (legacyValue === null) {
        return protectedValue;
      }
      if (legacyValue.length === 0 || legacyValue === protectedValue) {
        // Exact match (e.g. migration interrupted right after Asset Store write) or empty legacy residue: safe to clean.
        try {
          await this.deps.deleteLegacyFallback(key);
        } catch (_err) {
          // Non-fatal on read; next read/write will retry cleanup.
        }
        return protectedValue;
      }
      // Conflict: Asset Store holds A while legacy fallback holds a DIFFERENT value B.
      // Because 0.1.1 had no timestamps we cannot know whether A or B is newer — do NOT silently delete B!
      // Preserve both A and B intact until an explicit write() or delete() resolves the conflict.
      return protectedValue;
    }

    if (legacyValue === null) {
      return null;
    }
    if (legacyValue.length === 0) {
      await this.deps.deleteLegacyFallback(key);
      return null;
    }

    // Per-key migration: persist to Asset Store and verify read-back match BEFORE deleting legacy fallback.
    await this.writeToAssetStoreVerified(key, legacyValue);
    await this.deps.deleteLegacyFallback(key);
    return legacyValue;
  }

  async write(key: string, value: string): Promise<boolean> {
    if (key.length === 0) {
      throw new Error('凭据键名不能为空');
    }
    if (value.length === 0) {
      return await this.delete(key);
    }
    const markerKey: string = buildPendingDeleteMarkerKey(key, this.deps.encodeUtf8);
    const pendingDelete: boolean = await this.deps.readPendingDeleteMarker(markerKey);
    if (pendingDelete) {
      // Clear stale legacy fallback immediately if an earlier logout was pending before replacing with new value.
      await this.deps.deleteLegacyFallback(key);
    }
    await this.writeToAssetStoreVerified(key, value);
    if (pendingDelete) {
      await this.deps.clearPendingDeleteMarker(markerKey);
    }
    await this.deps.deleteLegacyFallback(key);
    return true;
  }

  async delete(key: string): Promise<boolean> {
    if (key.length === 0) {
      return false;
    }
    const markerKey: string = buildPendingDeleteMarkerKey(key, this.deps.encodeUtf8);
    // 1. Durably persist pending-delete tombstone BEFORE mutating either credential store.
    await this.deps.writePendingDeleteMarker(markerKey);

    // 2. Delete legacy fallback first so an Asset Store failure/crash cannot resurrect plaintext fallback.
    await this.deps.deleteLegacyFallback(key);

    // 3. Remove Asset Store chunks + primary alias and verify removal.
    await this.removeAssetEntryVerified(key);

    // 4. Confirm legacy fallback is still absent before clearing tombstone.
    const remainingFallback: string | null = await this.deps.readLegacyFallback(key);
    if (remainingFallback !== null) {
      await this.deps.deleteLegacyFallback(key);
      const stillPresent: string | null = await this.deps.readLegacyFallback(key);
      if (stillPresent !== null) {
        throw new Error('旧版凭据存储清理校验失败，请重试');
      }
    }

    // 5. Both stores verified empty -> safe to clear pending-delete tombstone.
    await this.deps.clearPendingDeleteMarker(markerKey);
    return true;
  }
}

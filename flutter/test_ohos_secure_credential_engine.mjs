// Production execution tests for HarmonyOS OhosSecureCredentialEngine.ts.
// Runs directly against the real TypeScript module compiled by Hvigor into ets/modules.abc.
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const pluginsDir = path.join(
  __dirname,
  'ohos',
  'entry',
  'src',
  'main',
  'ets',
  'plugins',
);

// ArkTS imports omit `.ts` extensions (`from './OhosDynamicBridge'`).
// Register a minimal in-process resolve hook so Node executes production `.ts` files unmodified.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (
      (specifier.startsWith('./') || specifier.startsWith('../')) &&
      !specifier.endsWith('.ts') &&
      !specifier.endsWith('.js') &&
      !specifier.endsWith('.mjs')
    ) {
      return nextResolve(`${specifier}.ts`, context);
    }
    return nextResolve(specifier, context);
  },
});

const engineUrl = pathToFileURL(
  path.join(pluginsDir, 'OhosSecureCredentialEngine.ts'),
).href;
const bridgeUrl = pathToFileURL(
  path.join(pluginsDir, 'OhosDynamicBridge.ts'),
).href;

const { OhosSecureCredentialEngine, buildPendingDeleteMarkerKey } = await import(
  engineUrl
);
const { buildAssetAliasName } = await import(bridgeUrl);

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: false });

class SimulatedOhosStores {
  constructor() {
    this.assets = new Map(); // alias -> Uint8Array
    this.fallback = new Map(); // key -> string (legacy 0.1.1 Preferences)
    this.state = new Map(); // markerKey -> string (non-secret tombstone Preferences)
    this.fallbackPutCount = 0;
    this.locked = false;
    this.failNextAssetPut = null;
    this.failNextAssetRemove = null;
    this.failNextFallbackDelete = null;
    this.failAssetPutAtCall = null;
    this.failAssetRemoveAtCall = null;
    this.assetPutCalls = 0;
    this.assetRemoveCalls = 0;
  }

  seedAsset(key, value) {
    const alias = buildAssetAliasName(key);
    const bytes = encoder.encode(value);
    assert(bytes.byteLength <= 1024, '0.1.1 direct AssetStore seed must fit 1024B limit');
    this.assets.set(alias, bytes);
  }

  seedFallback(key, value) {
    this.fallback.set(key, value);
  }

  createColdStartEngine() {
    const self = this;
    return new OhosSecureCredentialEngine({
      async assetQueryBytes(alias) {
        if (self.locked) {
          throw new Error('系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)');
        }
        const bytes = self.assets.get(alias);
        return bytes === undefined ? null : bytes.slice(0, bytes.byteLength);
      },
      async assetPutBytes(alias, secretBytes) {
        if (self.locked) {
          throw new Error('系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)');
        }
        if (encoder.encode(alias).byteLength > 256) {
          throw new Error('AssetStore ALIAS exceeds 256 bytes');
        }
        if (secretBytes.byteLength > 1024) {
          throw new Error('AssetStore SECRET exceeds 1024 bytes');
        }
        self.assetPutCalls++;
        if (self.failNextAssetPut !== null) {
          const err = self.failNextAssetPut;
          self.failNextAssetPut = null;
          throw err;
        }
        if (self.failAssetPutAtCall !== null && self.assetPutCalls === self.failAssetPutAtCall) {
          self.failAssetPutAtCall = null;
          throw new Error('Simulated crash during AssetStore write');
        }
        self.assets.set(alias, secretBytes.slice(0, secretBytes.byteLength));
      },
      async assetRemoveAlias(alias) {
        if (self.locked) {
          throw new Error('系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)');
        }
        self.assetRemoveCalls++;
        if (self.failNextAssetRemove !== null) {
          const err = self.failNextAssetRemove;
          self.failNextAssetRemove = null;
          throw err;
        }
        if (self.failAssetRemoveAtCall !== null && self.assetRemoveCalls === self.failAssetRemoveAtCall) {
          self.failAssetRemoveAtCall = null;
          throw new Error('Simulated crash during AssetStore remove');
        }
        self.assets.delete(alias);
      },
      async readLegacyFallback(key) {
        return self.fallback.has(key) ? self.fallback.get(key) : null;
      },
      async deleteLegacyFallback(key) {
        if (self.failNextFallbackDelete !== null) {
          const err = self.failNextFallbackDelete;
          self.failNextFallbackDelete = null;
          throw err;
        }
        self.fallback.delete(key);
      },
      async readPendingDeleteMarker(markerKey) {
        return self.state.get(markerKey) === '1';
      },
      async writePendingDeleteMarker(markerKey) {
        self.state.set(markerKey, '1');
      },
      async clearPendingDeleteMarker(markerKey) {
        self.state.delete(markerKey);
      },
      encodeUtf8(text) {
        return encoder.encode(text);
      },
      decodeUtf8(bytes) {
        return decoder.decode(bytes);
      },
    });
  }

  assertNoSecretPlaintextInState(secrets) {
    assert.equal(this.fallbackPutCount, 0, 'Must never write plaintext into legacy fallback');
    for (const [k, v] of this.state.entries()) {
      assert.equal(v, '1', `State store must only contain tombstone marker '1', got ${v}`);
      for (const secret of secrets) {
        assert(!k.includes(secret), 'State store key leaked secret');
        assert(!v.includes(secret), 'State store value leaked secret');
      }
    }
  }
}

async function runTests() {
  // 1. Both stores hold SAME value (e.g. migration interrupted right before fallback delete)
  {
    const stores = new SimulatedOhosStores();
    stores.seedAsset('webdav_password', 'SamePass_011!');
    stores.seedFallback('webdav_password', 'SamePass_011!');
    const engine = stores.createColdStartEngine();
    const val = await engine.read('webdav_password');
    assert.equal(val, 'SamePass_011!');
    assert.equal(stores.fallback.has('webdav_password'), false, 'Same value fallback must be cleaned');
    // Cold start still reads A cleanly
    const coldVal = await stores.createColdStartEngine().read('webdav_password');
    assert.equal(coldVal, 'SamePass_011!');
    stores.assertNoSecretPlaintextInState(['SamePass_011!']);
    console.log('PASS 1: both stores same value -> cleans legacy fallback & survives cold start');
  }

  // 2. Both stores hold DIFFERENT values (0.1.1 AssetStore=A, fallback=B) -> MUST NOT silently delete B
  {
    const stores = new SimulatedOhosStores();
    stores.seedAsset('quark_cookie', 'AssetValue_A_011');
    stores.seedFallback('quark_cookie', 'FallbackValue_B_011');
    const engine1 = stores.createColdStartEngine();
    const val1 = await engine1.read('quark_cookie');
    assert.equal(val1, 'AssetValue_A_011');
    assert.equal(
      stores.fallback.get('quark_cookie'),
      'FallbackValue_B_011',
      'Different fallback B MUST NOT be silently deleted when recency is unknown',
    );
    // Repeated cold start still preserves both A and B
    const engine2 = stores.createColdStartEngine();
    assert.equal(await engine2.read('quark_cookie'), 'AssetValue_A_011');
    assert.equal(stores.fallback.get('quark_cookie'), 'FallbackValue_B_011');
    // Explicit write resolves conflict and cleans fallback B
    await engine2.write('quark_cookie', 'AuthoritativeValue_C_012');
    assert.equal(stores.fallback.has('quark_cookie'), false, 'Explicit write cleans old conflict B');
    assert.equal(
      await stores.createColdStartEngine().read('quark_cookie'),
      'AuthoritativeValue_C_012',
    );
    stores.assertNoSecretPlaintextInState([
      'AssetValue_A_011',
      'FallbackValue_B_011',
      'AuthoritativeValue_C_012',
    ]);
    console.log('PASS 2: both stores different values (A vs B) -> preserves B without silent delete, resolves on explicit write');
  }

  // 3. Long Cookie (>2.5 KB) migration, update, cold start, and complete chunk cleanup on delete
  {
    const stores = new SimulatedOhosStores();
    const longCookie1 = `BDUSS=${'长Cookie测试_'.repeat(180)}END1`;
    const longCookie2 = `QUARK=${'新网盘令牌_'.repeat(210)}END2`;
    assert(encoder.encode(longCookie1).byteLength > 2500);
    assert(encoder.encode(longCookie2).byteLength > 2800);

    stores.seedFallback('uc_cookie', longCookie1);
    const val = await stores.createColdStartEngine().read('uc_cookie');
    assert.equal(val, longCookie1);
    assert.equal(stores.fallback.has('uc_cookie'), false, 'Long cookie fallback cleaned after verified chunked migration');
    assert(stores.assets.size >= 4, 'Long cookie stored as manifest + chunks in Asset Store');

    // Cold start reads exact reassembled long cookie
    assert.equal(await stores.createColdStartEngine().read('uc_cookie'), longCookie1);

    // Update long cookie -> swaps generation & cleans old chunks
    const prevAssetCount = stores.assets.size;
    await stores.createColdStartEngine().write('uc_cookie', longCookie2);
    assert.equal(await stores.createColdStartEngine().read('uc_cookie'), longCookie2);
    assert(stores.assets.size <= prevAssetCount + 2, 'Old generation chunks must be cleaned up');

    // Delete removes all chunks & manifest
    await stores.createColdStartEngine().delete('uc_cookie');
    assert.equal(stores.assets.size, 0, 'All long-cookie chunks & manifest must be removed');
    assert.equal(await stores.createColdStartEngine().read('uc_cookie'), null);
    stores.assertNoSecretPlaintextInState([longCookie1, longCookie2]);
    console.log('PASS 3: long Cookie (>2.5KB) migration, chunk swap, cold start & full cleanup');
  }

  // 4. Interrupted migration (both mid-write crash & post-write/pre-fallback-delete crash) + cold start recovery
  {
    const stores = new SimulatedOhosStores();
    const longCookie = `MIGRATE_COOKIE=${'X'.repeat(2200)}`;
    stores.seedFallback('baidu_cookie', longCookie);

    // 4a) Crash midway through chunk 2 of Asset Store write -> fallback stays intact, orphan chunks rolled back
    stores.failAssetPutAtCall = 2;
    await assert.rejects(
      () => stores.createColdStartEngine().read('baidu_cookie'),
      /Simulated crash during AssetStore write/,
    );
    assert.equal(stores.fallback.get('baidu_cookie'), longCookie, 'Fallback must stay intact on failed migration');
    assert.equal(stores.assets.size, 0, 'Partial orphan chunks rolled back on failed migration');

    // 4b) Next cold start writes Asset Store completely, then crashes right before deleting fallback
    stores.failNextFallbackDelete = new Error('Simulated crash before fallback delete');
    await assert.rejects(
      () => stores.createColdStartEngine().read('baidu_cookie'),
      /Simulated crash before fallback delete/,
    );
    assert.equal(stores.fallback.get('baidu_cookie'), longCookie);
    assert(stores.assets.size >= 3, 'Asset Store write succeeded before fallback delete crash');

    // 4c) Third cold start sees exact match in Asset Store == fallback -> cleans fallback & returns cookie
    const recovered = await stores.createColdStartEngine().read('baidu_cookie');
    assert.equal(recovered, longCookie);
    assert.equal(stores.fallback.has('baidu_cookie'), false, 'Interrupted migration residue cleaned on cold start');
    stores.assertNoSecretPlaintextInState([longCookie]);
    console.log('PASS 4: migration interruption (mid-write & pre-cleanup) recovers cleanly across cold starts');
  }

  // 5. Interrupted logout/delete MUST resume on next cold start and NEVER re-migrate fallback!
  {
    // 5a) Delete interrupted by lock screen (24000005) while both Asset Store & fallback existed
    const storesA = new SimulatedOhosStores();
    storesA.seedAsset('ali_token', 'AssetToken_A');
    storesA.seedFallback('ali_token', 'FallbackToken_B');
    storesA.locked = true;
    await assert.rejects(
      () => storesA.createColdStartEngine().delete('ali_token'),
      /24000005/,
    );
    const markerA = buildPendingDeleteMarkerKey('ali_token', (t) => encoder.encode(t));
    assert.equal(storesA.state.get(markerA), '1', 'Pending-delete tombstone persisted');
    assert.equal(storesA.fallback.has('ali_token'), false, 'Fallback already purged before lock error');

    // Cold start while STILL locked must NOT return A
    await assert.rejects(
      () => storesA.createColdStartEngine().read('ali_token'),
      /24000005/,
    );
    // Unlock -> cold start resumes delete, removes A, clears tombstone, returns null
    storesA.locked = false;
    assert.equal(await storesA.createColdStartEngine().read('ali_token'), null);
    assert.equal(storesA.assets.size, 0, 'Asset Store entry removed on resumed delete');
    assert.equal(storesA.state.has(markerA), false, 'Tombstone cleared after both stores empty');
    storesA.assertNoSecretPlaintextInState(['AssetToken_A', 'FallbackToken_B']);

    // 5b) Crash AFTER pendingDelete persisted & AssetStore removed, BEFORE fallback deleted!
    // Next cold start MUST NOT re-migrate fallback back into Asset Store!
    const storesB = new SimulatedOhosStores();
    const staleSecret = 'LoggedOutSecret_MustNeverReturn';
    storesB.seedFallback('webdav_password', staleSecret);
    storesB.failNextFallbackDelete = new Error('Simulated I/O crash deleting fallback');
    await assert.rejects(
      () => storesB.createColdStartEngine().delete('webdav_password'),
      /Simulated I\/O crash deleting fallback/,
    );
    assert.equal(storesB.fallback.get('webdav_password'), staleSecret);
    assert.equal(storesB.assets.size, 0);

    // Cold start -> sees pendingDelete tombstone -> finishes deletion, NEVER migrates staleSecret!
    const afterColdStart = await storesB.createColdStartEngine().read('webdav_password');
    assert.equal(afterColdStart, null, 'Pending-delete credential must return null on cold start');
    assert.equal(storesB.assets.size, 0, 'Pending-delete credential MUST NOT be migrated into Asset Store');
    assert.equal(storesB.fallback.has('webdav_password'), false, 'Pending-delete fallback must be removed');
    storesB.assertNoSecretPlaintextInState([staleSecret]);

    // 5c) Chunked long-Cookie delete interrupted mid-chunk -> resumes cleanly on cold start
    const storesC = new SimulatedOhosStores();
    const longCookie = `LOGOUT_LONG=${'Z'.repeat(2400)}`;
    await storesC.createColdStartEngine().write('quark_cookie', longCookie);
    assert(storesC.assets.size >= 4);
    storesC.assetRemoveCalls = 0;
    storesC.failAssetRemoveAtCall = 2;
    await assert.rejects(
      () => storesC.createColdStartEngine().delete('quark_cookie'),
      /Simulated crash during AssetStore remove/,
    );
    assert(storesC.assets.size > 0, 'Primary manifest still present for resumable chunk cleanup');
    assert.equal(await storesC.createColdStartEngine().read('quark_cookie'), null);
    assert.equal(storesC.assets.size, 0, 'All chunks + primary manifest cleaned after resumed delete');
    storesC.assertNoSecretPlaintextInState([longCookie]);

    // 5d) Re-login (`write`) after interrupted delete: fails cleanly when locked, succeeds when unlocked
    const storesD = new SimulatedOhosStores();
    storesD.seedFallback('webdav_password', 'StaleLogoutPass');
    storesD.failNextFallbackDelete = new Error('Fallback busy');
    await assert.rejects(() => storesD.createColdStartEngine().delete('webdav_password'));
    storesD.locked = true;
    await assert.rejects(() => storesD.createColdStartEngine().write('webdav_password', 'BrandNewPass'), /24000005/);
    storesD.locked = false;
    await storesD.createColdStartEngine().write('webdav_password', 'BrandNewPass');
    assert.equal(await storesD.createColdStartEngine().read('webdav_password'), 'BrandNewPass');
    assert.equal(storesD.fallback.has('webdav_password'), false);
    storesD.assertNoSecretPlaintextInState(['StaleLogoutPass', 'BrandNewPass']);

    console.log('PASS 5: logout/delete interruptions (lock screen, fallback-leftover, mid-chunk, re-login) all resume cleanly without re-migration');
  }

  console.log('ALL PRODUCTION OhosSecureCredentialEngine TESTS PASSED');
}

await runTests();

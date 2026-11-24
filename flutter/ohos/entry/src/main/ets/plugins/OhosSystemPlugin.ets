import {
  AbilityAware,
  AbilityPluginBinding,
  BinaryMessenger,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { preferences as dataPreferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  concatByteChunks,
  extractMethodArg,
  recordFromDynamicObject,
  stringArrayFromDynamicValue
} from './OhosDynamicBridge';
import {
  OhosSecureCredentialEngine,
  OhosSecureStorageDeps
} from './OhosSecureCredentialEngine';

const CHANNEL_NAME: string = 'com.pilipala.marcomovie/ohos_system';
const REMOTE_KEY_CHANNEL_NAME: string = 'com.pilipala.marcomovie/ohos_remote';
const OHOS_REMOTE_KEY_EVENT_NAME: string = 'MARCO_OHOS_REMOTE_KEY_EVENT';
const PATH_PROVIDER_CHANNEL: string = 'plugins.flutter.io/path_provider';
const SHARED_PREFS_CHANNEL: string = 'plugins.flutter.io/shared_preferences';
const PACKAGE_INFO_CHANNEL: string = 'dev.fluttercommunity.plus/package_info';
const URL_LAUNCHER_CHANNEL: string = 'plugins.flutter.io/url_launcher';
const PREFS_STORE_NAME: string = 'marco_movie_prefs';
const SECURE_FALLBACK_STORE_NAME: string = 'marco_movie_secure_fallback';
const SECURE_STATE_STORE_NAME: string = 'marco_movie_secure_state';
const ASSET_SERVICE_UNAVAILABLE_CODE: number = 24000001;
const ASSET_NOT_FOUND_CODE: number = 24000002;
const ASSET_DUPLICATE_CODE: number = 24000003;
const ASSET_ACCESS_DENIED_CODE: number = 24000004;
const ASSET_STATUS_MISMATCH_CODE: number = 24000005;

class PathProviderCompatHandler implements MethodCallHandler {
  private readonly host: OhosSystemPlugin;

  constructor(host: OhosSystemPlugin) {
    this.host = host;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.host.handlePathProviderCompat(call, result);
  }
}

class SharedPrefsCompatHandler implements MethodCallHandler {
  private readonly host: OhosSystemPlugin;

  constructor(host: OhosSystemPlugin) {
    this.host = host;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.host.dispatchSharedPrefsCompat(call, result);
  }
}

class PackageInfoCompatHandler implements MethodCallHandler {
  private readonly host: OhosSystemPlugin;

  constructor(host: OhosSystemPlugin) {
    this.host = host;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.host.handlePackageInfoCompat(call, result);
  }
}

class UrlLauncherCompatHandler implements MethodCallHandler {
  private readonly host: OhosSystemPlugin;

  constructor(host: OhosSystemPlugin) {
    this.host = host;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.host.handleUrlLauncherCompat(call, result);
  }
}

export class OhosSystemPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private remoteChannel: MethodChannel | null = null;
  private compatChannels: Array<MethodChannel> = [];
  private appContext: common.Context | null = null;
  private abilityContext: common.UIAbilityContext | null = null;
  private remoteBoundContext: common.UIAbilityContext | null = null;
  private readonly secureEngine: OhosSecureCredentialEngine;

  constructor(context?: common.UIAbilityContext) {
    if (context !== undefined) {
      this.abilityContext = context;
    }
    const deps: OhosSecureStorageDeps = {
      assetQueryBytes: (alias: string): Promise<Uint8Array | null> => this.assetQueryBytes(alias),
      assetPutBytes: (alias: string, secretBytes: Uint8Array): Promise<void> => this.assetPutBytes(alias, secretBytes),
      assetRemoveAlias: (alias: string): Promise<void> => this.assetRemoveAlias(alias),
      readLegacyFallback: (key: string): Promise<string | null> => this.readSecureFallback(key),
      deleteLegacyFallback: (key: string): Promise<void> => this.deleteSecureFallback(key),
      readPendingDeleteMarker: (markerKey: string): Promise<boolean> => this.readPendingDeleteMarker(markerKey),
      writePendingDeleteMarker: (markerKey: string): Promise<void> => this.writePendingDeleteMarker(markerKey),
      clearPendingDeleteMarker: (markerKey: string): Promise<void> => this.clearPendingDeleteMarker(markerKey),
      encodeUtf8: (text: string): Uint8Array => this.encodeUtf8(text),
      decodeUtf8: (bytes: Uint8Array): string => this.decodeUtf8(bytes)
    };
    this.secureEngine = new OhosSecureCredentialEngine(deps);
  }

  getUniqueClassName(): string {
    return 'OhosSystemPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.appContext = binding.getApplicationContext();
    const messenger: BinaryMessenger = binding.getBinaryMessenger();
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.remoteChannel = new MethodChannel(messenger, REMOTE_KEY_CHANNEL_NAME);
    this.registerStandardFlutterChannels(messenger);
    this.bindRemoteEventHubIfReady();
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.unbindRemoteEventHub();
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.remoteChannel = null;
    for (let i = 0; i < this.compatChannels.length; i++) {
      this.compatChannels[i].setMethodCallHandler(null);
    }
    this.compatChannels = [];
    this.appContext = null;
  }

  private bindRemoteEventHubIfReady(): void {
    if (this.abilityContext === null || this.remoteChannel === null) {
      return;
    }
    if (this.remoteBoundContext === this.abilityContext) {
      return;
    }
    this.unbindRemoteEventHub();
    this.remoteBoundContext = this.abilityContext;
    this.remoteBoundContext.eventHub.on(OHOS_REMOTE_KEY_EVENT_NAME, (payload: Record<string, Object>) => {
      if (this.remoteChannel !== null) {
        this.remoteChannel.invokeMethod('onRemoteKeyEvent', payload);
      }
    });
  }

  private unbindRemoteEventHub(): void {
    if (this.remoteBoundContext !== null) {
      try {
        this.remoteBoundContext.eventHub.off(OHOS_REMOTE_KEY_EVENT_NAME);
      } catch (_err) {
        // Ignore teardown errors when ability context is already destroyed.
      }
      this.remoteBoundContext = null;
    }
  }

  private registerStandardFlutterChannels(messenger: BinaryMessenger): void {
    const pathCh: MethodChannel = new MethodChannel(messenger, PATH_PROVIDER_CHANNEL);
    pathCh.setMethodCallHandler(new PathProviderCompatHandler(this));

    const prefsCh: MethodChannel = new MethodChannel(messenger, SHARED_PREFS_CHANNEL);
    prefsCh.setMethodCallHandler(new SharedPrefsCompatHandler(this));

    const pkgCh: MethodChannel = new MethodChannel(messenger, PACKAGE_INFO_CHANNEL);
    pkgCh.setMethodCallHandler(new PackageInfoCompatHandler(this));

    const urlCh: MethodChannel = new MethodChannel(messenger, URL_LAUNCHER_CHANNEL);
    urlCh.setMethodCallHandler(new UrlLauncherCompatHandler(this));

    this.compatChannels = [pathCh, prefsCh, pkgCh, urlCh];
  }

  handlePathProviderCompat(call: MethodCall, result: MethodResult): void {
    const dirs: Record<string, string> = this.handleGetDirectories();
    switch (call.method) {
      case 'getTemporaryDirectory':
        result.success(dirs['tempDir']);
        return;
      case 'getApplicationCacheDirectory':
        result.success(dirs['cacheDir']);
        return;
      case 'getApplicationDocumentsDirectory':
      case 'getApplicationSupportDirectory':
      case 'getLibraryDirectory':
      case 'getExternalStorageDirectory':
        result.success(dirs['filesDir']);
        return;
      default:
        result.notImplemented();
    }
  }

  handlePackageInfoCompat(_call: MethodCall, result: MethodResult): void {
    this.handleGetPackageInfo().then((info: Record<string, string>) => {
      info['buildSignature'] = '';
      result.success(info);
    }).catch((err: Error) => {
      result.error('OHOS_PKG_ERR', err.message, null);
    });
  }

  handleUrlLauncherCompat(call: MethodCall, result: MethodResult): void {
    if (call.method === 'canLaunch') {
      result.success(true);
      return;
    }
    if (call.method === 'launch' || call.method === 'launchUrl') {
      const url: string = String(this.getArg(call, 'url') ?? '');
      this.handleOpenExternalUrl(url)
        .then((ok: boolean) => result.success(ok))
        .catch(() => result.success(false));
      return;
    }
    result.notImplemented();
  }

  async dispatchSharedPrefsCompat(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      switch (call.method) {
        case 'getAll':
        case 'getAllWithParameters':
          result.success(await this.handlePrefsGetAll());
          return;
        case 'setBool':
          result.success(await this.handlePrefsSet(String(this.getArg(call, 'key') ?? ''), 'bool', this.getArg(call, 'value')));
          return;
        case 'setInt':
          result.success(await this.handlePrefsSet(String(this.getArg(call, 'key') ?? ''), 'int', this.getArg(call, 'value')));
          return;
        case 'setDouble':
          result.success(await this.handlePrefsSet(String(this.getArg(call, 'key') ?? ''), 'double', this.getArg(call, 'value')));
          return;
        case 'setString':
          result.success(await this.handlePrefsSet(String(this.getArg(call, 'key') ?? ''), 'string', this.getArg(call, 'value')));
          return;
        case 'setStringList':
          result.success(await this.handlePrefsSet(String(this.getArg(call, 'key') ?? ''), 'stringList', this.getArg(call, 'value')));
          return;
        case 'remove':
          result.success(await this.handlePrefsRemove(String(this.getArg(call, 'key') ?? '')));
          return;
        case 'clear':
        case 'clearWithParameters':
          result.success(await this.handlePrefsClear());
          return;
        default:
          result.notImplemented();
      }
    } catch (err) {
      result.error('OHOS_PREFS_ERR', String(err), null);
    }
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityContext = binding.getAbility().context as common.UIAbilityContext;
    this.bindRemoteEventHubIfReady();
  }

  onDetachedFromAbility(): void {
    this.unbindRemoteEventHub();
    this.abilityContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.dispatchAsync(call, result);
  }

  private async dispatchAsync(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      switch (call.method) {
        case 'getDeviceProfile': {
          result.success(this.handleGetDeviceProfile());
          return;
        }
        case 'getDirectories': {
          result.success(this.handleGetDirectories());
          return;
        }
        case 'getPackageInfo': {
          result.success(await this.handleGetPackageInfo());
          return;
        }
        case 'prefsGetAll': {
          result.success(await this.handlePrefsGetAll());
          return;
        }
        case 'prefsSet': {
          const key: string = String(this.getArg(call, 'key') ?? '');
          const valueType: string = String(this.getArg(call, 'type') ?? 'string');
          const value: ESObject = this.getArg(call, 'value');
          result.success(await this.handlePrefsSet(key, valueType, value));
          return;
        }
        case 'prefsRemove': {
          const key: string = String(this.getArg(call, 'key') ?? '');
          result.success(await this.handlePrefsRemove(key));
          return;
        }
        case 'prefsClear': {
          result.success(await this.handlePrefsClear());
          return;
        }
        case 'secureRead': {
          const key: string = String(this.getArg(call, 'key') ?? '');
          result.success(await this.handleSecureRead(key));
          return;
        }
        case 'secureWrite': {
          const key: string = String(this.getArg(call, 'key') ?? '');
          const rawValue: ESObject = this.getArg(call, 'value');
          if (rawValue === null || rawValue === undefined) {
            result.success(await this.handleSecureDelete(key));
          } else {
            result.success(await this.handleSecureWrite(key, String(rawValue)));
          }
          return;
        }
        case 'secureDelete': {
          const key: string = String(this.getArg(call, 'key') ?? '');
          result.success(await this.handleSecureDelete(key));
          return;
        }
        case 'pickJsonFile': {
          result.success(await this.handlePickJsonFile());
          return;
        }
        case 'pickDocumentFile': {
          const purpose: string = String(this.getArg(call, 'purpose') ?? 'subscription');
          const extensions: Array<string> = stringArrayFromDynamicValue(this.getArg(call, 'extensions'));
          const rawMaxBytes: ESObject = this.getArg(call, 'maxBytes');
          const maxBytes: number = rawMaxBytes === undefined || rawMaxBytes === null
            ? 16 * 1024 * 1024
            : Math.max(1024, Math.trunc(Number(rawMaxBytes)));
          const rawAsBytes: ESObject = this.getArg(call, 'asBytes');
          const asBytes: boolean = rawAsBytes === undefined || rawAsBytes === null ? true : Boolean(rawAsBytes);
          result.success(await this.handlePickDocumentFile(purpose, extensions, maxBytes, asBytes));
          return;
        }
        case 'saveTextFile': {
          const fileName: string = String(this.getArg(call, 'fileName') ?? 'marco_movie_export.json');
          const content: string = String(this.getArg(call, 'content') ?? '');
          const rawMaxBytes: ESObject = this.getArg(call, 'maxBytes');
          const maxBytes: number = rawMaxBytes === undefined || rawMaxBytes === null
            ? 0
            : Math.max(0, Math.trunc(Number(rawMaxBytes)));
          result.success(await this.handleSaveTextFile(fileName, content, maxBytes));
          return;
        }
        case 'openExternalUrl': {
          const url: string = String(this.getArg(call, 'url') ?? '');
          result.success(await this.handleOpenExternalUrl(url));
          return;
        }
        case 'setKeepScreenOn': {
          const enabled: boolean = Boolean(this.getArg(call, 'enabled'));
          result.success(await this.handleSetKeepScreenOn(enabled));
          return;
        }
        case 'setPreferredOrientation': {
          const mode: string = String(this.getArg(call, 'mode') ?? 'auto');
          result.success(await this.handleSetPreferredOrientation(mode));
          return;
        }
        default: {
          result.notImplemented();
          return;
        }
      }
    } catch (err) {
      const error = err as BusinessError;
      result.error(
        String(error?.code ?? 'OHOS_SYSTEM_ERROR'),
        String(error?.message ?? String(err)),
        null
      );
    }
  }

  private getArg(call: MethodCall, key: string): ESObject {
    return extractMethodArg(call, key);
  }

  private requireContext(): common.Context {
    if (this.abilityContext !== null) {
      return this.abilityContext;
    }
    if (this.appContext !== null) {
      return this.appContext;
    }
    throw new Error('OhosSystemPlugin context is not attached');
  }

  private normalizeDeviceType(raw: string): string {
    const lower: string = (raw || 'phone').toLowerCase();
    if (lower === 'tablet') {
      return 'tablet';
    }
    if (lower === '2in1' || lower === 'pc') {
      return '2in1';
    }
    if (lower === 'tv' || lower === 'smartvision') {
      return 'tv';
    }
    return 'phone';
  }

  private handleGetDeviceProfile(): Record<string, Object> {
    const normalizedType: string = this.normalizeDeviceType(String(deviceInfo.deviceType ?? 'phone'));
    const profile: Record<string, Object> = {
      'deviceType': normalizedType,
      'osFullName': String(deviceInfo.osFullName ?? ''),
      'sdkApiVersion': Math.trunc(Number(deviceInfo.sdkApiVersion ?? 12))
    };
    return profile;
  }

  private handleGetDirectories(): Record<string, string> {
    const context: common.Context = this.requireContext();
    const dirs: Record<string, string> = {
      'filesDir': String(context.filesDir ?? ''),
      'cacheDir': String(context.cacheDir ?? ''),
      'tempDir': String(context.tempDir ?? '')
    };
    return dirs;
  }

  private async handleGetPackageInfo(): Promise<Record<string, string>> {
    const bundleInfo: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
    );
    const info: Record<string, string> = {
      'appName': 'Marco Movie',
      'packageName': String(bundleInfo.name ?? 'com.pilipala.marcomovie'),
      'version': String(bundleInfo.versionName ?? '0.1.2'),
      'buildNumber': String(bundleInfo.versionCode ?? 1000003)
    };
    return info;
  }

  private async getPrefsStore(name: string): Promise<dataPreferences.Preferences> {
    return await dataPreferences.getPreferences(this.requireContext(), name);
  }

  private async handlePrefsGetAll(): Promise<Record<string, Object>> {
    const prefs: dataPreferences.Preferences = await this.getPrefsStore(PREFS_STORE_NAME);
    const allObj: Object = await prefs.getAll();
    return recordFromDynamicObject(allObj);
  }

  private async handlePrefsSet(key: string, valueType: string, value: ESObject): Promise<boolean> {
    if (key.length === 0) {
      return false;
    }
    const prefs: dataPreferences.Preferences = await this.getPrefsStore(PREFS_STORE_NAME);
    switch (valueType) {
      case 'int': {
        await prefs.put(key, Math.trunc(Number(value ?? 0)));
        break;
      }
      case 'double': {
        await prefs.put(key, Number(value ?? 0));
        break;
      }
      case 'bool': {
        await prefs.put(key, Boolean(value));
        break;
      }
      case 'stringList': {
        const list: Array<string> = stringArrayFromDynamicValue(value);
        await prefs.put(key, list);
        break;
      }
      case 'string':
      default: {
        await prefs.put(key, String(value ?? ''));
        break;
      }
    }
    await prefs.flush();
    return true;
  }

  private async handlePrefsRemove(key: string): Promise<boolean> {
    if (key.length === 0) {
      return false;
    }
    const prefs: dataPreferences.Preferences = await this.getPrefsStore(PREFS_STORE_NAME);
    await prefs.delete(key);
    await prefs.flush();
    return true;
  }

  private async handlePrefsClear(): Promise<boolean> {
    const prefs: dataPreferences.Preferences = await this.getPrefsStore(PREFS_STORE_NAME);
    await prefs.clear();
    await prefs.flush();
    return true;
  }

  private encodeUtf8(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const encoded: Uint8Array = encoder.encodeInto(text);
    return encoded.slice(0, encoded.byteLength);
  }

  private decodeUtf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  private buildAssetAliasBytes(alias: string): Uint8Array {
    return this.encodeUtf8(alias);
  }

  private sanitizeAssetError(operation: string, err: ESObject): Error {
    const error = err as BusinessError;
    const code: number = Math.trunc(Number(error?.code ?? 0));
    if (code === ASSET_STATUS_MISMATCH_CODE) {
      return new Error('系统安全存储当前不可用（设备锁屏或尚未首次解锁），请解锁后重试 (code=24000005)');
    }
    if (code === ASSET_SERVICE_UNAVAILABLE_CODE) {
      return new Error('系统安全存储服务暂不可用，请稍后重试 (code=24000001)');
    }
    if (code === ASSET_ACCESS_DENIED_CODE) {
      return new Error('系统安全存储拒绝访问，请检查应用签名状态后重试 (code=24000004)');
    }
    const suffix: string = code !== 0 ? ' (code=' + String(code) + ')' : '';
    return new Error('系统安全存储' + operation + '失败，请稍后重试' + suffix);
  }

  private async assetQueryBytes(alias: string): Promise<Uint8Array | null> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.buildAssetAliasBytes(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const records: Array<asset.AssetMap> = await asset.query(query);
      if (records.length === 0) {
        return null;
      }
      const secretValue: asset.Value | undefined = records[0].get(asset.Tag.SECRET);
      if (secretValue instanceof Uint8Array) {
        return secretValue.slice(0, secretValue.byteLength);
      }
      return null;
    } catch (err) {
      const error = err as BusinessError;
      if (Number(error?.code ?? 0) === ASSET_NOT_FOUND_CODE) {
        return null;
      }
      throw this.sanitizeAssetError('读取', err);
    }
  }

  private async assetPutBytes(alias: string, secretBytes: Uint8Array): Promise<void> {
    const aliasBytes: Uint8Array = this.buildAssetAliasBytes(alias);
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, aliasBytes);
    attrs.set(asset.Tag.SECRET, secretBytes);
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attrs);
    } catch (addErr) {
      const addError = addErr as BusinessError;
      if (Number(addError?.code ?? 0) === ASSET_DUPLICATE_CODE) {
        try {
          const query: asset.AssetMap = new Map();
          query.set(asset.Tag.ALIAS, aliasBytes);
          const updateAttrs: asset.AssetMap = new Map();
          updateAttrs.set(asset.Tag.SECRET, secretBytes);
          await asset.update(query, updateAttrs);
        } catch (updateErr) {
          throw this.sanitizeAssetError('更新', updateErr);
        }
      } else {
        throw this.sanitizeAssetError('写入', addErr);
      }
    }
  }

  private async assetRemoveAlias(alias: string): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.buildAssetAliasBytes(alias));
      await asset.remove(query);
    } catch (err) {
      const error = err as BusinessError;
      if (Number(error?.code ?? 0) === ASSET_NOT_FOUND_CODE) {
        return;
      }
      throw this.sanitizeAssetError('删除', err);
    }
  }

  private async handleSecureRead(key: string): Promise<string | null> {
    return await this.secureEngine.read(key);
  }

  private async handleSecureWrite(key: string, value: string): Promise<boolean> {
    return await this.secureEngine.write(key, value);
  }

  private async handleSecureDelete(key: string): Promise<boolean> {
    return await this.secureEngine.delete(key);
  }

  private async readPendingDeleteMarker(markerKey: string): Promise<boolean> {
    const stateStore: dataPreferences.Preferences = await this.getPrefsStore(SECURE_STATE_STORE_NAME);
    const exists: boolean = await stateStore.has(markerKey);
    if (!exists) {
      return false;
    }
    const val: dataPreferences.ValueType = await stateStore.get(markerKey, '');
    return String(val) === '1';
  }

  private async writePendingDeleteMarker(markerKey: string): Promise<void> {
    const stateStore: dataPreferences.Preferences = await this.getPrefsStore(SECURE_STATE_STORE_NAME);
    await stateStore.put(markerKey, '1');
    await stateStore.flush();
  }

  private async clearPendingDeleteMarker(markerKey: string): Promise<void> {
    const stateStore: dataPreferences.Preferences = await this.getPrefsStore(SECURE_STATE_STORE_NAME);
    const exists: boolean = await stateStore.has(markerKey);
    if (exists) {
      await stateStore.delete(markerKey);
      await stateStore.flush();
    }
  }

  private async readSecureFallback(key: string): Promise<string | null> {
    const fallback: dataPreferences.Preferences = await this.getPrefsStore(SECURE_FALLBACK_STORE_NAME);
    const exists: boolean = await fallback.has(key);
    if (!exists) {
      return null;
    }
    const val: dataPreferences.ValueType = await fallback.get(key, '');
    return String(val);
  }

  private async deleteSecureFallback(key: string): Promise<void> {
    const fallback: dataPreferences.Preferences = await this.getPrefsStore(SECURE_FALLBACK_STORE_NAME);
    const exists: boolean = await fallback.has(key);
    if (exists) {
      await fallback.delete(key);
      await fallback.flush();
    }
  }

  private extractFileName(uri: string, fallbackName: string): string {
    const trimmedFallback: string = fallbackName.trim();
    if (trimmedFallback.length > 0 && trimmedFallback.indexOf('/') === -1) {
      try {
        return decodeURIComponent(trimmedFallback);
      } catch (_err) {
        return trimmedFallback;
      }
    }
    const cleanUri: string = uri.split('?')[0];
    const parts: Array<string> = cleanUri.split('/');
    const tail: string = parts.length > 0 ? parts[parts.length - 1] : 'selected.json';
    try {
      return decodeURIComponent(tail);
    } catch (_err) {
      return tail;
    }
  }

  private resolveSuffixFilters(purpose: string, requestedExtensions: Array<string>): Array<string> {
    const cleaned: Array<string> = [];
    for (let i = 0; i < requestedExtensions.length; i++) {
      const ext: string = requestedExtensions[i].trim().toLowerCase();
      if (ext.length === 0) {
        continue;
      }
      const normalized: string = ext.startsWith('.') ? ext : '.' + ext;
      if (cleaned.indexOf(normalized) === -1) {
        cleaned.push(normalized);
      }
    }
    if (cleaned.length > 0) {
      return cleaned;
    }
    if (purpose === 'backup') {
      return ['.json'];
    }
    if (purpose === 'live') {
      return ['.m3u', '.m3u8', '.txt', '.json'];
    }
    return ['.json', '.zip', '.txt', '.m3u', '.m3u8'];
  }

  private formatByteLimitLabel(maxBytes: number): string {
    const mb: number = Math.max(1, Math.round(maxBytes / (1024 * 1024)));
    return String(mb) + ' MB';
  }

  private async readPickedUriBytesAsync(uri: string, maxBytes: number): Promise<Uint8Array> {
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      try {
        const stat: fs.Stat = await fs.stat(file.fd);
        if (stat.size > maxBytes) {
          throw new Error('FILE_TOO_LARGE:所选文件超过 ' + this.formatByteLimitLabel(maxBytes) + ' 限制');
        }
      } catch (statErr) {
        if (statErr instanceof Error && statErr.message.startsWith('FILE_TOO_LARGE:')) {
          throw statErr;
        }
        // Some virtual document URIs report stat errors; enforce limit strictly during chunked read below.
      }
      const chunks: Array<Uint8Array> = [];
      let totalBytes: number = 0;
      const chunkBuffer: ArrayBuffer = new ArrayBuffer(65536);
      while (true) {
        const bytesRead: number = await fs.read(file.fd, chunkBuffer);
        if (bytesRead <= 0) {
          break;
        }
        totalBytes += bytesRead;
        if (totalBytes > maxBytes) {
          throw new Error('FILE_TOO_LARGE:所选文件超过 ' + this.formatByteLimitLabel(maxBytes) + ' 限制');
        }
        const copy: Uint8Array = new Uint8Array(bytesRead);
        copy.set(new Uint8Array(chunkBuffer, 0, bytesRead));
        chunks.push(copy);
      }
      return concatByteChunks(chunks);
    } finally {
      try {
        await fs.close(file);
      } catch (_closeErr) {
        // Ignore close errors.
      }
    }
  }

  private async handlePickDocumentFile(
    purpose: string,
    requestedExtensions: Array<string>,
    maxBytes: number,
    asBytes: boolean
  ): Promise<Record<string, Object> | null> {
    const context: common.Context = this.requireContext();
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = this.resolveSuffixFilters(purpose, requestedExtensions);
    const selectedUris: Array<string> = await documentPicker.select(options);
    if (!selectedUris || selectedUris.length === 0 || !selectedUris[0]) {
      return null;
    }
    const uri: string = selectedUris[0];
    const merged: Uint8Array = await this.readPickedUriBytesAsync(uri, maxBytes);
    const fileName: string = this.extractFileName(uri, '');
    if (asBytes) {
      const payload: Record<string, Object> = {
        'name': fileName,
        'path': uri,
        'bytes': merged,
        'size': merged.byteLength
      };
      return payload;
    }
    const textPayload: Record<string, Object> = {
      'name': fileName,
      'path': uri,
      'content': this.decodeUtf8(merged),
      'size': merged.byteLength
    };
    return textPayload;
  }

  private async handlePickJsonFile(): Promise<Record<string, string> | null> {
    const picked: Record<string, Object> | null = await this.handlePickDocumentFile(
      'subscription',
      ['.json', '.txt', '.m3u', '.m3u8'],
      16 * 1024 * 1024,
      false
    );
    if (picked === null) {
      return null;
    }
    const payload: Record<string, string> = {
      'name': String(picked['name'] ?? 'selected.json'),
      'path': String(picked['path'] ?? ''),
      'content': String(picked['content'] ?? '')
    };
    return payload;
  }

  private async handleSaveTextFile(
    fileName: string,
    content: string,
    maxBytes: number = 0
  ): Promise<string | null> {
    const encoded: Uint8Array = this.encodeUtf8(content);
    if (maxBytes > 0 && encoded.byteLength > maxBytes) {
      throw new Error('FILE_TOO_LARGE:导出文件超过 ' + this.formatByteLimitLabel(maxBytes) + ' 限制');
    }
    const context: common.Context = this.requireContext();
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    const savedUris: Array<string> = await documentPicker.save(saveOptions);
    if (!savedUris || savedUris.length === 0 || !savedUris[0]) {
      return null;
    }
    const uri: string = savedUris[0];
    const file: fs.File = await fs.open(
      uri,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
    );
    try {
      let writtenTotal: number = 0;
      while (writtenTotal < encoded.byteLength) {
        const remainingSlice: ArrayBuffer = encoded.buffer.slice(
          encoded.byteOffset + writtenTotal,
          encoded.byteOffset + encoded.byteLength
        );
        const written: number = await fs.write(file.fd, remainingSlice);
        if (written <= 0) {
          throw new Error('写入文件未完成，请重试');
        }
        writtenTotal += written;
      }
      return uri;
    } finally {
      try {
        await fs.close(file);
      } catch (_closeErr) {
        // Ignore close errors.
      }
    }
  }

  private async handleOpenExternalUrl(url: string): Promise<boolean> {
    const trimmed: string = url.trim();
    if (trimmed.length === 0 || this.abilityContext === null) {
      return false;
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: trimmed
      };
      await this.abilityContext.startAbility(want);
      return true;
    } catch (_err) {
      return false;
    }
  }

  private async handleSetKeepScreenOn(enabled: boolean): Promise<boolean> {
    const win: window.Window = await window.getLastWindow(this.requireContext());
    await win.setWindowKeepScreenOn(Boolean(enabled));
    return true;
  }

  private async handleSetPreferredOrientation(mode: string): Promise<boolean> {
    const win: window.Window = await window.getLastWindow(this.requireContext());
    let orientation: window.Orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
    if (mode === 'landscape') {
      orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
    } else if (mode === 'portrait') {
      orientation = window.Orientation.PORTRAIT;
    } else {
      orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
    }
    await win.setPreferredOrientation(orientation);
    return true;
  }
}

export default OhosSystemPlugin;

import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult
} from '@ohos/flutter_ohos';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { dataPreferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';

const CHANNEL_NAME: string = 'com.pilipala.marcomovie/ohos_system';
const PATH_PROVIDER_CHANNEL: string = 'plugins.flutter.io/path_provider';
const SHARED_PREFS_CHANNEL: string = 'plugins.flutter.io/shared_preferences';
const PACKAGE_INFO_CHANNEL: string = 'dev.fluttercommunity.plus/package_info';
const URL_LAUNCHER_CHANNEL: string = 'plugins.flutter.io/url_launcher';
const PREFS_STORE_NAME: string = 'marco_movie_prefs';
const SECURE_FALLBACK_STORE_NAME: string = 'marco_movie_secure_fallback';
const ASSET_NOT_FOUND_CODE: number = 24000002;
const ASSET_DUPLICATE_CODE: number = 24000003;

export class OhosSystemPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private compatChannels: Array<MethodChannel> = [];
  private appContext: common.Context | null = null;
  private abilityContext: common.UIAbilityContext | null = null;

  constructor(context?: common.UIAbilityContext) {
    if (context !== undefined) {
      this.abilityContext = context;
    }
  }

  getUniqueClassName(): string {
    return 'OhosSystemPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.appContext = binding.getApplicationContext();
    const messenger = binding.getBinaryMessenger();
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.registerStandardFlutterChannels(messenger);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    if (this.channel !== null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    for (const compat of this.compatChannels) {
      compat.setMethodCallHandler(null);
    }
    this.compatChannels = [];
    this.appContext = null;
  }

  private registerStandardFlutterChannels(messenger: ESObject): void {
    const pathCh = new MethodChannel(messenger, PATH_PROVIDER_CHANNEL);
    pathCh.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        const dirs = this.handleGetDirectories();
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
    });

    const prefsCh = new MethodChannel(messenger, SHARED_PREFS_CHANNEL);
    prefsCh.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.dispatchSharedPrefsCompat(call, result);
      }
    });

    const pkgCh = new MethodChannel(messenger, PACKAGE_INFO_CHANNEL);
    pkgCh.setMethodCallHandler({
      onMethodCall: (_call: MethodCall, result: MethodResult): void => {
        this.handleGetPackageInfo().then((info) => {
          info['buildSignature'] = '';
          result.success(info);
        }).catch((err: Error) => {
          result.error('OHOS_PKG_ERR', err.message, null);
        });
      }
    });

    const urlCh = new MethodChannel(messenger, URL_LAUNCHER_CHANNEL);
    urlCh.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method === 'canLaunch') {
          result.success(true);
          return;
        }
        if (call.method === 'launch' || call.method === 'launchUrl') {
          const url: string = String(this.getArg(call, 'url') ?? '');
          this.handleOpenExternalUrl(url).then((ok) => result.success(ok)).catch(() => result.success(false));
          return;
        }
        result.notImplemented();
      }
    });

    this.compatChannels = [pathCh, prefsCh, pkgCh, urlCh];
  }

  private async dispatchSharedPrefsCompat(call: MethodCall, result: MethodResult): Promise<void> {
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
  }

  onDetachedFromAbility(): void {
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
        case 'saveTextFile': {
          const fileName: string = String(this.getArg(call, 'fileName') ?? 'marco_movie_export.json');
          const content: string = String(this.getArg(call, 'content') ?? '');
          result.success(await this.handleSaveTextFile(fileName, content));
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
    const callObj: ESObject = call as ESObject;
    if (typeof callObj.argument === 'function') {
      const val: ESObject = callObj.argument(key);
      if (val !== undefined) {
        return val;
      }
    }
    const args: ESObject = call.args;
    if (args === null || args === undefined) {
      return undefined;
    }
    if (args instanceof Map) {
      return args.get(key);
    }
    return args[key];
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
      'version': String(bundleInfo.versionName ?? '0.1.0'),
      'buildNumber': String(bundleInfo.versionCode ?? 1000001)
    };
    return info;
  }

  private async getPrefsStore(name: string): Promise<dataPreferences.Preferences> {
    return await dataPreferences.getPreferences(this.requireContext(), name);
  }

  private async handlePrefsGetAll(): Promise<Record<string, Object>> {
    const prefs: dataPreferences.Preferences = await this.getPrefsStore(PREFS_STORE_NAME);
    const allObj: ESObject = await prefs.getAll();
    const out: Record<string, Object> = {};
    if (allObj === null || allObj === undefined) {
      return out;
    }
    if (allObj instanceof Map) {
      allObj.forEach((value: Object, key: string) => {
        if (value !== undefined && value !== null) {
          out[String(key)] = value;
        }
      });
      return out;
    }
    const keys: Array<string> = Object.keys(allObj);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const v: ESObject = allObj[k];
      if (v !== undefined && v !== null) {
        out[k] = v as Object;
      }
    }
    return out;
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
        const list: Array<string> = [];
        if (Array.isArray(value)) {
          const rawArr: Array<ESObject> = value as Array<ESObject>;
          for (let i = 0; i < rawArr.length; i++) {
            list.push(String(rawArr[i] ?? ''));
          }
        }
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

  private buildAssetAlias(key: string): Uint8Array {
    return this.encodeUtf8('marco_movie:' + key);
  }

  private async handleSecureRead(key: string): Promise<string | null> {
    if (key.length === 0) {
      return null;
    }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.buildAssetAlias(key));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const records: Array<asset.AssetMap> = await asset.query(query);
      if (records.length > 0) {
        const secretValue: asset.Value | undefined = records[0].get(asset.Tag.SECRET);
        if (secretValue instanceof Uint8Array) {
          return this.decodeUtf8(secretValue);
        }
      }
    } catch (err) {
      const error = err as BusinessError;
      if (error?.code === ASSET_NOT_FOUND_CODE) {
        return await this.readSecureFallback(key);
      }
      return await this.readSecureFallback(key);
    }
    return await this.readSecureFallback(key);
  }

  private async handleSecureWrite(key: string, value: string): Promise<boolean> {
    if (key.length === 0) {
      return false;
    }
    const aliasBytes: Uint8Array = this.buildAssetAlias(key);
    const secretBytes: Uint8Array = this.encodeUtf8(value);
    try {
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, aliasBytes);
      attrs.set(asset.Tag.SECRET, secretBytes);
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      try {
        await asset.add(attrs);
      } catch (addErr) {
        const addError = addErr as BusinessError;
        if (addError?.code === ASSET_DUPLICATE_CODE) {
          const query: asset.AssetMap = new Map();
          query.set(asset.Tag.ALIAS, aliasBytes);
          const updateAttrs: asset.AssetMap = new Map();
          updateAttrs.set(asset.Tag.SECRET, secretBytes);
          await asset.update(query, updateAttrs);
        } else {
          throw addErr;
        }
      }
      await this.deleteSecureFallback(key);
      return true;
    } catch (_err) {
      await this.writeSecureFallback(key, value);
      return true;
    }
  }

  private async handleSecureDelete(key: string): Promise<boolean> {
    if (key.length === 0) {
      return false;
    }
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.buildAssetAlias(key));
      await asset.remove(query);
    } catch (_err) {
      // Ignore ASSET_NOT_FOUND or unavailable HUKS on unconfigured emulators.
    }
    await this.deleteSecureFallback(key);
    return true;
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

  private async writeSecureFallback(key: string, value: string): Promise<void> {
    const fallback: dataPreferences.Preferences = await this.getPrefsStore(SECURE_FALLBACK_STORE_NAME);
    await fallback.put(key, value);
    await fallback.flush();
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
    if (fallbackName.length > 0 && fallbackName.indexOf('/') === -1) {
      return fallbackName;
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

  private async handlePickJsonFile(): Promise<Record<string, string> | null> {
    const context: common.Context = this.requireContext();
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json', '.txt', '.m3u', '.m3u8'];
    const selectedUris: Array<string> = await documentPicker.select(options);
    if (!selectedUris || selectedUris.length === 0 || !selectedUris[0]) {
      return null;
    }
    const uri: string = selectedUris[0];
    const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const chunks: Array<Uint8Array> = [];
      let totalBytes: number = 0;
      const chunkBuffer: ArrayBuffer = new ArrayBuffer(65536);
      while (true) {
        const bytesRead: number = fs.readSync(file.fd, chunkBuffer);
        if (bytesRead <= 0) {
          break;
        }
        const copy: Uint8Array = new Uint8Array(bytesRead);
        copy.set(new Uint8Array(chunkBuffer, 0, bytesRead));
        chunks.push(copy);
        totalBytes += bytesRead;
      }
      const merged: Uint8Array = new Uint8Array(totalBytes);
      let offset: number = 0;
      for (let i = 0; i < chunks.length; i++) {
        merged.set(chunks[i], offset);
        offset += chunks[i].byteLength;
      }
      const content: string = this.decodeUtf8(merged);
      const fileName: string = this.extractFileName(uri, String(file.name ?? ''));
      const payload: Record<string, string> = {
        'name': fileName,
        'path': uri,
        'content': content
      };
      return payload;
    } finally {
      fs.closeSync(file);
    }
  }

  private async handleSaveTextFile(fileName: string, content: string): Promise<string | null> {
    const context: common.Context = this.requireContext();
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    const savedUris: Array<string> = await documentPicker.save(saveOptions);
    if (!savedUris || savedUris.length === 0 || !savedUris[0]) {
      return null;
    }
    const uri: string = savedUris[0];
    const file: fs.File = fs.openSync(
      uri,
      fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
    );
    try {
      const encoded: Uint8Array = this.encodeUtf8(content);
      const exactBuffer: ArrayBuffer = encoded.buffer.slice(
        encoded.byteOffset,
        encoded.byteOffset + encoded.byteLength
      );
      fs.writeSync(file.fd, exactBuffer);
      return uri;
    } finally {
      fs.closeSync(file);
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

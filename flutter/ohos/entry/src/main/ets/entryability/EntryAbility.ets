import { FlutterAbility, FlutterEngine, MethodChannel } from '@ohos/flutter_ohos';
import { window } from '@kit.ArkUI';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { OhosSystemPlugin } from '../plugins/OhosSystemPlugin';
import { OhosAvPlayerPlugin } from '../plugins/OhosAvPlayerPlugin';

export const OHOS_REMOTE_KEY_EVENT: string = 'MARCO_OHOS_REMOTE_KEY_EVENT';
const REMOTE_KEY_CHANNEL_NAME: string = 'com.pilipala.marcomovie/ohos_remote';

export default class EntryAbility extends FlutterAbility {
  private remoteChannel: MethodChannel | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    flutterEngine.getPlugins()?.add(new OhosSystemPlugin(this.context));
    flutterEngine.getPlugins()?.add(new OhosAvPlayerPlugin());

    this.remoteChannel = new MethodChannel(
      flutterEngine.getDartExecutor().getBinaryMessenger(),
      REMOTE_KEY_CHANNEL_NAME
    );
    this.context.eventHub.on(OHOS_REMOTE_KEY_EVENT, (payload: Record<string, Object>) => {
      if (this.remoteChannel !== null) {
        this.remoteChannel.invokeMethod('onRemoteKeyEvent', payload);
      }
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    windowStage.getMainWindow().then((mainWin: window.Window) => {
      try {
        mainWin.setWindowBackgroundColor('#0E1015');
      } catch (_err) {
        // Non-fatal on headless/test window stages.
      }
    }).catch(() => {});
  }

  onDestroy(): Promise<void> {
    this.context.eventHub.off(OHOS_REMOTE_KEY_EVENT);
    this.remoteChannel = null;
    return super.onDestroy();
  }
}

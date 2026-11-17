import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { window } from '@kit.ArkUI';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { OhosSystemPlugin } from '../plugins/OhosSystemPlugin';
import { OhosAvPlayerPlugin } from '../plugins/OhosAvPlayerPlugin';

export const OHOS_REMOTE_KEY_EVENT: string = 'MARCO_OHOS_REMOTE_KEY_EVENT';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    flutterEngine.getPlugins()?.add(new OhosSystemPlugin(this.context));
    flutterEngine.getPlugins()?.add(new OhosAvPlayerPlugin());
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
}

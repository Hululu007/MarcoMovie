import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { FlutterPage } from '@ohos/flutter_ohos';
import { OHOS_REMOTE_KEY_EVENT } from '../entryability/EntryAbility';

let storage: LocalStorage = LocalStorage.getShared();
const EVENT_BACK_PRESS: string = 'EVENT_BACK_PRESS';

@Entry(storage)
@Component
struct Index {
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  @LocalStorageLink('viewId') viewId: string = '';

  private mapRemoteKeyAction(keyCode: number): string {
    switch (keyCode) {
      case KeyCode.KEYCODE_DPAD_UP:
        return 'dpad_up';
      case KeyCode.KEYCODE_DPAD_DOWN:
        return 'dpad_down';
      case KeyCode.KEYCODE_DPAD_LEFT:
        return 'dpad_left';
      case KeyCode.KEYCODE_DPAD_RIGHT:
        return 'dpad_right';
      case KeyCode.KEYCODE_DPAD_CENTER:
      case KeyCode.KEYCODE_ENTER:
      case KeyCode.KEYCODE_NUMPAD_ENTER:
        return 'select';
      case KeyCode.KEYCODE_MENU:
        return 'menu';
      case KeyCode.KEYCODE_MEDIA_PLAY_PAUSE:
        return 'play_pause';
      case KeyCode.KEYCODE_MEDIA_PLAY:
        return 'play';
      case KeyCode.KEYCODE_MEDIA_PAUSE:
        return 'pause';
      case KeyCode.KEYCODE_BACK:
      case KeyCode.KEYCODE_ESCAPE:
        return 'back';
      default:
        return 'other';
    }
  }

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0E1015')
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent): boolean => {
      const payload: Record<string, Object> = {
        'keyCode': Math.trunc(Number(event.keyCode)),
        'type': Math.trunc(Number(event.type)),
        'logicalAction': this.mapRemoteKeyAction(event.keyCode)
      };
      this.context.eventHub.emit(OHOS_REMOTE_KEY_EVENT, payload);
      // Return false so FlutterPage/XComponent continues receiving native KeyEventChannel events.
      return false;
    })
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS);
    return true;
  }
}

import { FlutterEngine, Log } from '@ohos/flutter_ohos';

const TAG: string = 'GeneratedPluginRegistrant';

export class GeneratedPluginRegistrant {
  static registerWith(flutterEngine: FlutterEngine): void {
    try {
      // Populated automatically by `flutter build hap` when OHOS plugins are declared.
    } catch (err) {
      Log.e(TAG, 'Failed to register generated Flutter plugins: ' + String(err));
    }
  }
}

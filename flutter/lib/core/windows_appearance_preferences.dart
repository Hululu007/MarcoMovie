import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Portable appearance settings deliberately exclude machine-local photo paths.
class WindowsAppearancePreferences {
  static const key = 'windowsAppearance';
  static const prefix = 'windows_v4_';
  static final revision = ValueNotifier<int>(0);
  static const choices = <String, List<String>>{
    'preset': [
      'obsidian',
      'slate',
      'midnight',
      'ink',
      'paper',
      'mist',
      // Legacy presets kept valid so older backups restore cleanly.
      'dusk',
      'sea',
      'sunset',
      'forest',
      'rose',
    ],
    'mode': ['auto', 'light', 'dark'],
    'position': ['top', 'center', 'bottom'],
  };
  static Map<String, dynamic> export(SharedPreferences prefs) => {
        'version': 1,
        for (final field in [...choices.keys, 'brightness', 'blur'])
          if (prefs.containsKey('$prefix$field'))
            field: prefs.get('$prefix$field'),
      };
  static Map<String, dynamic> validate(dynamic value) {
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('Windows 外观备份版本无效');
    }
    final result = <String, dynamic>{};
    for (final field in choices.keys) {
      if (!value.containsKey(field)) continue;
      if (!choices[field]!.contains(value[field])) {
        throw FormatException('Windows 外观 $field 无效');
      }
      result[field] = value[field];
    }
    for (final field in ['brightness', 'blur']) {
      if (!value.containsKey(field)) continue;
      final number = value[field];
      final min = field == 'blur' ? 0 : .35;
      final max = field == 'blur' ? 40 : 1.1;
      if (number is! num || !number.isFinite || number < min || number > max) {
        throw FormatException('Windows 外观 $field 无效');
      }
      result[field] = number.toDouble();
    }
    return result;
  }

  static Future<void> restore(
    SharedPreferences prefs,
    Map<String, dynamic> values, {
    Future<void> Function(String key, String value, String label)? setString,
    Future<void> Function(String key, double value, String label)? setDouble,
  }) async {
    for (final entry in values.entries) {
      final key = '$prefix${entry.key}';
      final value = entry.value;
      if (value is String) {
        if (setString != null) {
          await setString(key, value, 'Windows 外观设置');
        } else {
          final ok = await prefs.setString(key, value);
          if (!ok) throw StateError('Windows 外观设置恢复失败');
        }
      } else {
        final doubleVal = value as double;
        if (setDouble != null) {
          await setDouble(key, doubleVal, 'Windows 外观设置');
        } else {
          final ok = await prefs.setDouble(key, doubleVal);
          if (!ok) throw StateError('Windows 外观设置恢复失败');
        }
      }
    }
    // A backup selects a portable preset; the imported photo remains available locally.
    if (setString != null) {
      await setString('${prefix}image', '', 'Windows 外观背景设置');
    } else {
      final clearedImage = await prefs.setString('${prefix}image', '');
      if (!clearedImage) throw StateError('Windows 外观背景设置恢复失败');
    }
    revision.value++;
  }
}

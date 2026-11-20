// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ohos_runtime.dart';

/// Immutable snapshot of local device-only player HUD & gesture preferences.
///
/// Stored strictly in local [SharedPreferences] under snake_case keys and never
/// serialized into cross-device backup payloads.
@immutable
class PlayerHudPrefsData {
  final String doubleTapCenter;
  final String doubleTapSides;
  final String longPressRestoreMode;
  final bool startSpecHud;
  final bool slimProgress;
  final bool skipCountdown;

  const PlayerHudPrefsData({
    required this.doubleTapCenter,
    required this.doubleTapSides,
    required this.longPressRestoreMode,
    required this.startSpecHud,
    required this.slimProgress,
    required this.skipCountdown,
  });

  factory PlayerHudPrefsData.defaultsFor({required bool isDesktop}) {
    return PlayerHudPrefsData(
      doubleTapCenter: isDesktop ? 'fullscreen' : 'play_pause',
      doubleTapSides: isDesktop ? 'fullscreen' : 'seek_10s',
      longPressRestoreMode: 'previous',
      startSpecHud: true,
      slimProgress: true,
      skipCountdown: true,
    );
  }

  /// Side double-tap seek step in seconds (`5`, `10`, `15`), or `0` if side
  /// double-tap is configured for play/pause or fullscreen.
  int get sideSeekSeconds => switch (doubleTapSides) {
        'seek_5s' => 5,
        'seek_10s' => 10,
        'seek_15s' => 15,
        _ => 0,
      };

  PlayerHudPrefsData copyWith({
    String? doubleTapCenter,
    String? doubleTapSides,
    String? longPressRestoreMode,
    bool? startSpecHud,
    bool? slimProgress,
    bool? skipCountdown,
  }) {
    return PlayerHudPrefsData(
      doubleTapCenter: doubleTapCenter ?? this.doubleTapCenter,
      doubleTapSides: doubleTapSides ?? this.doubleTapSides,
      longPressRestoreMode: longPressRestoreMode ?? this.longPressRestoreMode,
      startSpecHud: startSpecHud ?? this.startSpecHud,
      slimProgress: slimProgress ?? this.slimProgress,
      skipCountdown: skipCountdown ?? this.skipCountdown,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayerHudPrefsData &&
      other.doubleTapCenter == doubleTapCenter &&
      other.doubleTapSides == doubleTapSides &&
      other.longPressRestoreMode == longPressRestoreMode &&
      other.startSpecHud == startSpecHud &&
      other.slimProgress == slimProgress &&
      other.skipCountdown == skipCountdown;

  @override
  int get hashCode => Object.hash(
        doubleTapCenter,
        doubleTapSides,
        longPressRestoreMode,
        startSpecHud,
        slimProgress,
        skipCountdown,
      );
}

/// Manages local player HUD preferences with OHOS isolation guards.
class PlayerHudPrefs extends ChangeNotifier {
  static const String keyDoubleTapCenter = 'player_double_tap_center';
  static const String keyDoubleTapSides = 'player_double_tap_sides';
  static const String keyLongPressRestoreMode =
      'player_long_press_restore_mode';
  static const String keyStartSpecHud = 'player_start_spec_hud';
  static const String keySlimProgress = 'player_slim_progress';
  static const String keySkipCountdown = 'player_skip_countdown';

  static const Set<String> validCenterActions = <String>{
    'play_pause',
    'fullscreen',
    'none',
  };

  static const Set<String> validSideActions = <String>{
    'seek_5s',
    'seek_10s',
    'seek_15s',
    'play_pause',
    'fullscreen',
  };

  static const Set<String> validRestoreModes = <String>{
    'previous',
    '1.0x',
  };

  final bool isDesktop;
  final bool _persist;
  SharedPreferences? _prefs;
  PlayerHudPrefsData _data;
  bool _disposed = false;

  PlayerHudPrefs({
    required this.isDesktop,
    PlayerHudPrefsData? initial,
    SharedPreferences? prefs,
    bool persist = true,
  })  : _prefs = prefs,
        _persist = persist,
        _data = initial ?? PlayerHudPrefsData.defaultsFor(isDesktop: isDesktop);

  /// Synchronous test/in-memory factory that never hits platform storage.
  factory PlayerHudPrefs.inMemory({
    bool isDesktop = false,
    PlayerHudPrefsData? initial,
  }) {
    return PlayerHudPrefs(
      isDesktop: isDesktop,
      initial: initial,
      persist: false,
    );
  }

  PlayerHudPrefsData get data => _data;

  /// Whether enhanced Wave 1 M2 player HUD features are active (always off on
  /// HarmonyOS NEXT per cross-platform isolation rules).
  bool get enhancedHudEnabled => !OhosRuntime.isOhos;

  bool get effectiveStartSpecHud => enhancedHudEnabled && _data.startSpecHud;
  bool get effectiveSlimProgress => enhancedHudEnabled && _data.slimProgress;
  bool get effectiveSkipCountdown => enhancedHudEnabled && _data.skipCountdown;

  Future<void> load() async {
    if (!_persist || _disposed) return;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (_disposed) return;
      final defaults = PlayerHudPrefsData.defaultsFor(isDesktop: isDesktop);
      final rawCenter = prefs.getString(keyDoubleTapCenter);
      final rawSides = prefs.getString(keyDoubleTapSides);
      final rawRestore = prefs.getString(keyLongPressRestoreMode);
      final next = PlayerHudPrefsData(
        doubleTapCenter:
            rawCenter != null && validCenterActions.contains(rawCenter)
                ? rawCenter
                : defaults.doubleTapCenter,
        doubleTapSides: rawSides != null && validSideActions.contains(rawSides)
            ? rawSides
            : defaults.doubleTapSides,
        longPressRestoreMode:
            rawRestore != null && validRestoreModes.contains(rawRestore)
                ? rawRestore
                : defaults.longPressRestoreMode,
        startSpecHud: prefs.getBool(keyStartSpecHud) ?? defaults.startSpecHud,
        slimProgress: prefs.getBool(keySlimProgress) ?? defaults.slimProgress,
        skipCountdown:
            prefs.getBool(keySkipCountdown) ?? defaults.skipCountdown,
      );
      if (next != _data && !_disposed) {
        _data = next;
        notifyListeners();
      }
    } catch (_) {
      // Keep safe platform defaults when SharedPreferences is unavailable.
    }
  }

  Future<void> setDoubleTapCenter(String value) async {
    if (!validCenterActions.contains(value) || _disposed) return;
    _update(_data.copyWith(doubleTapCenter: value));
    await _writeString(keyDoubleTapCenter, value);
  }

  Future<void> setDoubleTapSides(String value) async {
    if (!validSideActions.contains(value) || _disposed) return;
    _update(_data.copyWith(doubleTapSides: value));
    await _writeString(keyDoubleTapSides, value);
  }

  Future<void> setLongPressRestoreMode(String value) async {
    if (!validRestoreModes.contains(value) || _disposed) return;
    _update(_data.copyWith(longPressRestoreMode: value));
    await _writeString(keyLongPressRestoreMode, value);
  }

  Future<void> setStartSpecHud(bool value) async {
    if (_disposed) return;
    _update(_data.copyWith(startSpecHud: value));
    await _writeBool(keyStartSpecHud, value);
  }

  Future<void> setSlimProgress(bool value) async {
    if (_disposed) return;
    _update(_data.copyWith(slimProgress: value));
    await _writeBool(keySlimProgress, value);
  }

  Future<void> setSkipCountdown(bool value) async {
    if (_disposed) return;
    _update(_data.copyWith(skipCountdown: value));
    await _writeBool(keySkipCountdown, value);
  }

  void _update(PlayerHudPrefsData next) {
    if (next == _data || _disposed) return;
    _data = next;
    notifyListeners();
  }

  Future<void> _writeString(String key, String value) async {
    if (!_persist || _disposed) return;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  Future<void> _writeBool(String key, bool value) async {
    if (!_persist || _disposed) return;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'ios_mpv_profile.dart' show MpvPropertySetter;

/// Frame-pacing and display-sync strategy for macOS `vo=libmpv` playback.
enum MacosVideoSyncMode {
  auto(
    id: 'auto',
    labelZh: '自动帧率同步（推荐）',
    shortLabelZh: '自动同步',
    descriptionZh:
        '检测到 CVDisplayLink 垂直同步后自动启用显示器同步（display-resample），'
        '在 120 Hz / ProMotion 下以精确 5:1 节拍输出 23.976/24 fps，直播与降级路径自动回退音频同步',
  ),
  displayResample(
    id: 'display_resample',
    labelZh: '显示器同步（无插帧）',
    shortLabelZh: '显示器同步',
    descriptionZh:
        '锁定屏幕刷新节拍并微调音频采样率（display-resample），保持电影胶片质感、消除周期性掉帧',
  ),
  smoothInterpolation(
    id: 'smooth_interpolation',
    labelZh: '显示器同步 + 平滑插帧（60 Hz 防抖）',
    shortLabelZh: '平滑插帧',
    descriptionZh:
        '在显示器同步基础上开启 OpenGL 时间插值（interpolation），显著减轻 60 Hz 固定刷新率下 24 fps 横移抖动',
  ),
  off(
    id: 'off',
    labelZh: '音频基准同步（原版默认）',
    shortLabelZh: '音频同步',
    descriptionZh: '使用 libmpv 传统 video-sync=audio 模式，不做显示器节拍重采样与插帧',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;

  const MacosVideoSyncMode({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
  });

  static const MacosVideoSyncMode defaultMode = MacosVideoSyncMode.auto;

  static MacosVideoSyncMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in MacosVideoSyncMode.values) {
      if (mode.id == normalized) return mode;
    }
    return defaultMode;
  }
}

/// Temporal interpolation kernel (`tscale`) used when
/// [MacosVideoSyncMode.smoothInterpolation] is active.
enum MacosVideoSyncTscale {
  oversample(
    id: 'oversample',
    mpvValue: 'oversample',
    labelZh: 'Oversample（锐利电影感·推荐）',
    descriptionZh: '仅在帧边界做轻量混合，消除 3:2 抖动同时保留清晰度',
  ),
  mitchell(
    id: 'mitchell',
    mpvValue: 'mitchell',
    labelZh: 'Mitchell（顺滑柔和）',
    descriptionZh: '平滑过渡相邻帧，适合慢速长镜头横移画面',
  );

  final String id;
  final String mpvValue;
  final String labelZh;
  final String descriptionZh;

  const MacosVideoSyncTscale({
    required this.id,
    required this.mpvValue,
    required this.labelZh,
    required this.descriptionZh,
  });

  static const MacosVideoSyncTscale defaultTscale =
      MacosVideoSyncTscale.oversample;

  static MacosVideoSyncTscale fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final item in MacosVideoSyncTscale.values) {
      if (item.id == normalized) return item;
    }
    return defaultTscale;
  }
}

/// Snapshot of the macOS display hosting `MainFlutterWindow` and whether the
/// `media_kit_video` OpenGL render loop is paced by `CVDisplayLink`.
@immutable
class MacosDisplayRefreshInfo {
  static const double minValidHz = 23.0;
  static const double maxValidHz = 480.0;

  final double refreshRateHz;
  final bool vsyncPaced;
  final bool isVariableRefresh;
  final String source;
  final String screenName;

  const MacosDisplayRefreshInfo({
    required this.refreshRateHz,
    required this.vsyncPaced,
    this.isVariableRefresh = false,
    this.source = 'unknown',
    this.screenName = '',
  });

  static const MacosDisplayRefreshInfo unavailable = MacosDisplayRefreshInfo(
    refreshRateHz: 0,
    vsyncPaced: false,
    source: 'unavailable',
  );

  double get effectiveDisplayFps =>
      (refreshRateHz.isFinite &&
              refreshRateHz >= minValidHz &&
              refreshRateHz <= maxValidHz)
          ? refreshRateHz
          : 0.0;

  bool get isHighRefresh => effectiveDisplayFps >= 90.0;

  String get formattedRefreshRate {
    final hz = effectiveDisplayFps;
    if (hz <= 0) return '未检测到';
    final rounded = hz.roundToDouble();
    final base = (hz - rounded).abs() < 0.05
        ? '${rounded.toInt()} Hz'
        : '${hz.toStringAsFixed(2)} Hz';
    return isVariableRefresh ? '$base（ProMotion）' : base;
  }

  static MacosDisplayRefreshInfo? tryParseMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final hz = (map['refreshRateHz'] as num?)?.toDouble() ?? 0.0;
    final vsync = map['vsyncPaced'] == true;
    final vrr = map['isVariableRefresh'] == true;
    final source = (map['source'] ?? 'unknown').toString();
    final screenName = (map['screenName'] ?? '').toString();
    return MacosDisplayRefreshInfo(
      refreshRateHz: hz.isFinite ? hz : 0.0,
      vsyncPaced: vsync,
      isVariableRefresh: vrr,
      source: source,
      screenName: screenName,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MacosDisplayRefreshInfo &&
      (other.refreshRateHz - refreshRateHz).abs() < 0.01 &&
      other.vsyncPaced == vsyncPaced &&
      other.isVariableRefresh == isVariableRefresh &&
      other.source == source &&
      other.screenName == screenName;

  @override
  int get hashCode => Object.hash(
        (refreshRateHz * 100).round(),
        vsyncPaced,
        isVariableRefresh,
        source,
        screenName,
      );
}

/// Resolved set of libmpv properties for the active macOS playback session.
@immutable
class MacosVideoSyncPlan {
  final MacosVideoSyncMode requestedMode;
  final bool appliedDisplaySync;
  final bool appliedInterpolation;
  final double displayFpsOverride;
  final Map<String, String> mpvProperties;
  final String reason;

  const MacosVideoSyncPlan({
    required this.requestedMode,
    required this.appliedDisplaySync,
    required this.appliedInterpolation,
    required this.displayFpsOverride,
    required this.mpvProperties,
    required this.reason,
  });
}

/// Computes and applies safe, verified libmpv display-sync parameters on macOS.
///
/// Safety invariant: `video-sync=display-resample` + `display-fps-override` is
/// ONLY enabled when the native `TextureHW` OpenGL render loop is paced by
/// `CVDisplayLink` (`display.vsyncPaced == true`) and playback is non-live VOD.
/// On non-vsync-paced render paths, setting `display-fps-override` causes
/// libmpv to spin unthrottled and drift A/V sync by >1000 ms; this policy
/// guarantees safe fallback to `video-sync=audio`.
class MacosVideoSyncPolicy {
  const MacosVideoSyncPolicy._();

  static MacosVideoSyncPlan resolve({
    required MacosVideoSyncMode mode,
    required MacosVideoSyncTscale tscale,
    required MacosDisplayRefreshInfo display,
    required bool isLive,
  }) {
    if (isLive) {
      return const MacosVideoSyncPlan(
        requestedMode: MacosVideoSyncMode.off,
        appliedDisplaySync: false,
        appliedInterpolation: false,
        displayFpsOverride: 0,
        mpvProperties: <String, String>{
          'video-sync': 'audio',
          'interpolation': 'no',
          'display-fps-override': '0',
        },
        reason: 'live_stream_uses_audio_sync',
      );
    }

    if (mode == MacosVideoSyncMode.off) {
      return const MacosVideoSyncPlan(
        requestedMode: MacosVideoSyncMode.off,
        appliedDisplaySync: false,
        appliedInterpolation: false,
        displayFpsOverride: 0,
        mpvProperties: <String, String>{
          'video-sync': 'audio',
          'interpolation': 'no',
          'display-fps-override': '0',
        },
        reason: 'user_selected_audio_sync',
      );
    }

    final fps = display.effectiveDisplayFps;
    if (!display.vsyncPaced || fps <= 0) {
      return MacosVideoSyncPlan(
        requestedMode: mode,
        appliedDisplaySync: false,
        appliedInterpolation: false,
        displayFpsOverride: 0,
        mpvProperties: const <String, String>{
          'video-sync': 'audio',
          'interpolation': 'no',
          'display-fps-override': '0',
        },
        reason: !display.vsyncPaced
            ? 'fallback_non_vsync_render_path'
            : 'fallback_unknown_display_hz',
      );
    }

    final useInterpolation = mode == MacosVideoSyncMode.smoothInterpolation;
    final formattedFps = fps.toStringAsFixed(3);
    return MacosVideoSyncPlan(
      requestedMode: mode,
      appliedDisplaySync: true,
      appliedInterpolation: useInterpolation,
      displayFpsOverride: fps,
      mpvProperties: <String, String>{
        'video-sync': 'display-resample',
        'display-fps-override': formattedFps,
        'video-sync-max-video-change': '5',
        'interpolation': useInterpolation ? 'yes' : 'no',
        if (useInterpolation) 'tscale': tscale.mpvValue,
      },
      reason: useInterpolation
          ? 'cvdisplaylink_display_resample_with_interpolation'
          : 'cvdisplaylink_display_resample',
    );
  }

  static Future<MacosVideoSyncPlan> applyWithSetter(
    MpvPropertySetter setProperty, {
    required MacosVideoSyncMode mode,
    required MacosVideoSyncTscale tscale,
    required MacosDisplayRefreshInfo display,
    required bool isLive,
  }) async {
    final plan = resolve(
      mode: mode,
      tscale: tscale,
      display: display,
      isLive: isLive,
    );
    for (final entry in plan.mpvProperties.entries) {
      await setProperty(entry.key, entry.value);
    }
    return plan;
  }

  static Future<MacosVideoSyncPlan> applyToPlayer(
    Player player, {
    required MacosVideoSyncMode mode,
    required MacosVideoSyncTscale tscale,
    required MacosDisplayRefreshInfo display,
    required bool isLive,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) {
      return resolve(
        mode: mode,
        tscale: tscale,
        display: display,
        isLive: isLive,
      );
    }
    return applyWithSetter(
      (key, value) async {
        try {
          await platform.setProperty(key, value);
        } catch (_) {}
      },
      mode: mode,
      tscale: tscale,
      display: display,
      isLive: isLive,
    );
  }
}

/// Platform bridge to `MainFlutterWindow` (`marco_movie/macos_window`) for
/// display refresh rate queries and live monitor-switch / fullscreen updates.
class MacosDisplayRefreshBridge {
  static const MethodChannel _channel =
      MethodChannel('marco_movie/macos_window');
  static final StreamController<MacosDisplayRefreshInfo> _changesController =
      StreamController<MacosDisplayRefreshInfo>.broadcast();
  static bool _handlerInstalled = false;

  @visibleForTesting
  static Future<MacosDisplayRefreshInfo> Function()? debugQueryOverride;

  static Stream<MacosDisplayRefreshInfo> get changes {
    ensureInstalled();
    return _changesController.stream;
  }

  static void ensureInstalled() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDisplayRefreshRateChanged' &&
          call.arguments is Map) {
        final parsed = MacosDisplayRefreshInfo.tryParseMap(
          call.arguments as Map<Object?, Object?>,
        );
        if (parsed != null && !_changesController.isClosed) {
          _changesController.add(parsed);
        }
      }
      return null;
    });
  }

  @visibleForTesting
  static void debugEmitDisplayRefreshChange(MacosDisplayRefreshInfo info) {
    if (!_changesController.isClosed) {
      _changesController.add(info);
    }
  }

  static Future<MacosDisplayRefreshInfo> query() async {
    final override = debugQueryOverride;
    if (override != null) {
      return override();
    }
    if (kIsWeb || !Platform.isMacOS) {
      return MacosDisplayRefreshInfo.unavailable;
    }
    ensureInstalled();
    try {
      final raw = await _channel.invokeMethod<dynamic>('getDisplayRefreshInfo');
      if (raw is Map) {
        return MacosDisplayRefreshInfo.tryParseMap(raw) ??
            MacosDisplayRefreshInfo.unavailable;
      }
    } catch (_) {}
    return MacosDisplayRefreshInfo.unavailable;
  }
}


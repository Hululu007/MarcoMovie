// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ohos_runtime.dart';

/// Windows x64 `libmpv` (`vo=libmpv` offscreen texture pipeline) video quality
/// and HDR tone-mapping presets.
enum WindowsQualityPreset {
  ecoCompat(
    id: 'ecoCompat',
    labelZh: '省电兼容',
    shortLabelZh: '省电',
    descriptionZh: '低功耗 / 老核显兼容：bilinear 缩放，关闭 HDR 动态峰值与去色带',
    baseScale: 'bilinear',
    baseCscale: 'bilinear',
    dscale: 'bilinear',
  ),
  balancedHq(
    id: 'balancedHq',
    labelZh: '高画质 HDR 映射',
    shortLabelZh: '高画质',
    descriptionZh:
        '默认推荐：spline36 + mitchell 缩放，开启 HDR 动态色调映射与感知色域映射',
    baseScale: 'spline36',
    baseCscale: 'spline36',
    dscale: 'mitchell',
  ),
  cinemaUltra(
    id: 'cinemaUltra',
    labelZh: '旗舰超清锐利',
    shortLabelZh: '旗舰',
    descriptionZh:
        'ewa_lanczossharp 超清缩放 + 去色带 (deband) + 高精度峰值检测与色彩提示',
    baseScale: 'ewa_lanczossharp',
    baseCscale: 'spline36',
    dscale: 'mitchell',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final String baseScale;
  final String baseCscale;
  final String dscale;

  const WindowsQualityPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.baseScale,
    required this.baseCscale,
    required this.dscale,
  });

  static WindowsQualityPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'ecocompat':
      case 'eco_compat':
      case 'eco':
        return WindowsQualityPreset.ecoCompat;
      case 'cinemaultra':
      case 'cinema_ultra':
      case 'cinema':
      case 'ultra':
        return WindowsQualityPreset.cinemaUltra;
      case 'balancedhq':
      case 'balanced_hq':
      case 'balanced':
      case '':
      default:
        return WindowsQualityPreset.balancedHq;
    }
  }
}

/// 4-tier parametric EQ vocal dialogue enhancement presets for stereo and
/// multi-channel (5.1/7.1) movie tracks on desktop speakers/headphones.
///
/// Uses mpv's built-in `format=format=floatp` bridge (backed by `libswresample`)
/// ahead of `lavfi=[equalizer=...]` so it runs cleanly on shipped LGPL
/// `libmpv-2.dll` builds that omit `dynaudnorm` and `lavfi`'s `aresample`.
/// Keeps `volume-max` at `100` (never fakes enhancement by raising volume).
enum AudioLoudnessPreset {
  off(
    id: 'off',
    labelZh: '关闭',
    shortLabelZh: '关闭',
    descriptionZh: '原声输出，不启用人声均衡增强',
    volumeMax: '100',
    audioFilter: '',
  ),
  light(
    id: 'light',
    labelZh: '轻度',
    shortLabelZh: '轻度',
    descriptionZh: '轻度人声频段清晰化，温和收敛低频轰鸣并预留防削顶余量',
    volumeMax: '100',
    audioFilter:
        'format=format=floatp,lavfi=[equalizer=f=90:t=q:w=0.85:g=-3.0,equalizer=f=1400:t=q:w=0.85:g=0.35,equalizer=f=3200:t=q:w=1.1:g=0.35]',
  ),
  standard(
    id: 'standard',
    labelZh: '标准',
    shortLabelZh: '标准',
    descriptionZh: '均衡突出人声对白、抑制低频浑浊与刺耳高频，兼顾高电平防削顶（推荐）',
    volumeMax: '100',
    audioFilter:
        'format=format=floatp,lavfi=[equalizer=f=90:t=q:w=0.85:g=-5.5,equalizer=f=180:t=q:w=1.5:g=-0.8,equalizer=f=1400:t=q:w=0.85:g=0.65,equalizer=f=3200:t=q:w=1.1:g=0.6,equalizer=f=9000:t=q:w=1.0:g=-1.2]',
  ),
  cinemaVocal(
    id: 'cinemaVocal',
    labelZh: '影院人声',
    shortLabelZh: '影院人声',
    descriptionZh: '强力抑制电影低频轰鸣与刺耳高频以凸显中置人声穿透力，预留防削顶余量',
    volumeMax: '100',
    audioFilter:
        'format=format=floatp,lavfi=[equalizer=f=85:t=q:w=0.85:g=-8.5,equalizer=f=180:t=q:w=1.5:g=-1.2,equalizer=f=1400:t=q:w=0.85:g=0.9,equalizer=f=3200:t=q:w=1.1:g=0.85,equalizer=f=9000:t=q:w=1.0:g=-2.5]',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final String volumeMax;
  final String audioFilter;

  const AudioLoudnessPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.volumeMax,
    required this.audioFilter,
  });

  static AudioLoudnessPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'light':
        return AudioLoudnessPreset.light;
      case 'standard':
        return AudioLoudnessPreset.standard;
      case 'cinemavocal':
      case 'cinema_vocal':
      case 'vocal':
        return AudioLoudnessPreset.cinemaVocal;
      case 'off':
      case '':
      default:
        return AudioLoudnessPreset.off;
    }
  }
}

typedef WindowsMpvPropertySetter = Future<void> Function(
  String key,
  String value,
);

/// Manages Windows `libmpv` video quality presets, HDR tone-mapping fallback
/// chain, smart `hwdec` linkage (zero-copy `d3d11va`/`auto-safe` vs
/// `d3d11va-copy` for Anime4K / compat kernel / software filters), and 4-tier
/// parametric EQ vocal enhancement with runtime audio-filter failure recovery.
class WindowsVideoQualityController extends ChangeNotifier {
  static const String prefKeyQualityPreset = 'windows_video_quality_preset';
  static const String prefKeyLoudnessPreset = 'windows_audio_loudness_preset';

  /// Ordered fallback chain for `tone-mapping` across newer and older `libmpv`
  /// / `libplacebo` builds.
  static const List<String> toneMappingFallbackChain = <String>[
    'bt.2446a',
    'bt.2390',
    'spline',
  ];

  static const String fallbackAudioFilter =
      'format=format=floatp,lavfi=[equalizer=f=90:t=q:w=0.85:g=-4.5,equalizer=f=1400:t=q:w=0.9:g=0.75]';

  static const String audioFallbackWarningZh =
      '当前播放器不支持人声增强滤镜，已自动恢复原声';

  final TargetPlatform? platformOverride;
  final bool? isOhosOverride;
  final bool? isWebOverride;
  final bool? isNativePlayerOverride;
  final WindowsMpvPropertySetter? propertySetterOverride;
  final bool persistLocally;
  final Duration? recoverySettleDelayOverride;
  SharedPreferences? _prefs;

  /// Optional test hook to inject a custom `af` graph (e.g., an unavailable
  /// filter like `lavfi=[dynaudnorm=f=150:g=15:p=0.95]`) when testing runtime
  /// recovery against real `libmpv-2.dll`.
  @visibleForTesting
  String? debugAudioFilterOverride;

  WindowsQualityPreset _qualityPreset;
  AudioLoudnessPreset _loudnessPreset;
  String _effectiveScale;
  String? _effectiveToneMapping;
  String _effectiveHwdec = 'auto-safe';
  String? _lastWarning;
  String _activeAppliedAudioFilter = '';
  bool _disposed = false;
  int _qualityOpGen = 0;
  int _loudnessOpGen = 0;
  int _recoverySessionGen = 0;
  int _recoveryTaskSeq = 0;
  int? _activeRecoveryTaskId;
  int? _activeRecoverySessionGen;
  Player? _activeRecoveryPlayer;
  bool _wasAttached = false;
  bool _audioFilterRecoverySuspended = false;
  Player? _attachedPlayer;
  VoidCallback? _onLoudnessFallbackToOff;
  StreamSubscription<Track>? _trackSub;
  StreamSubscription<PlayerLog>? _logSub;
  Timer? _pendingAudioRecoveryTimer;
  String? _lastActiveAudioTrackId;

  WindowsVideoQualityController({
    this.platformOverride,
    this.isOhosOverride,
    this.isWebOverride,
    this.isNativePlayerOverride,
    this.propertySetterOverride,
    this.recoverySettleDelayOverride,
    SharedPreferences? prefs,
    this.persistLocally = true,
    WindowsQualityPreset initialQualityPreset = WindowsQualityPreset.balancedHq,
    AudioLoudnessPreset initialLoudnessPreset = AudioLoudnessPreset.off,
  })  : _prefs = prefs,
        _qualityPreset = initialQualityPreset,
        _loudnessPreset = initialLoudnessPreset,
        _effectiveScale = initialQualityPreset.baseScale;

  WindowsQualityPreset get qualityPreset => _qualityPreset;
  AudioLoudnessPreset get loudnessPreset => _loudnessPreset;
  String get effectiveScale => _effectiveScale;
  String? get effectiveToneMapping => _effectiveToneMapping;
  String get effectiveHwdec => _effectiveHwdec;
  String? get lastWarning => _lastWarning;
  String get activeAppliedAudioFilter => _activeAppliedAudioFilter;
  String? get lastActiveAudioTrackId => _lastActiveAudioTrackId;

  /// Base `(scale, cscale)` corresponding to the active Windows quality preset,
  /// suitable for injecting into `Anime4kController.windowsBaseScalerResolver`.
  ({String scale, String cscale}) get activeBaseScalers {
    if (!isPlatformSupported) {
      return (scale: 'bilinear', cscale: 'bilinear');
    }
    if (_qualityPreset == WindowsQualityPreset.cinemaUltra) {
      return (
        scale: _effectiveScale,
        cscale: _qualityPreset.baseCscale,
      );
    }
    return (
      scale: _qualityPreset.baseScale,
      cscale: _qualityPreset.baseCscale,
    );
  }

  static bool isSupportedPlatform({
    TargetPlatform? platformOverride,
    bool? isOhosOverride,
    bool? isWebOverride,
  }) {
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    if (isWebOverride ?? kIsWeb) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.windows;
  }

  bool get isPlatformSupported => isSupportedPlatform(
        platformOverride: platformOverride,
        isOhosOverride: isOhosOverride,
        isWebOverride: isWebOverride,
      );

  bool isAvailableForPlayer(Player player) {
    if (!isPlatformSupported) return false;
    if (isNativePlayerOverride != null) return isNativePlayerOverride!;
    if (propertySetterOverride != null) return true;
    return player.platform is NativePlayer;
  }

  WindowsMpvPropertySetter? _resolveSetter(Player player) {
    if (propertySetterOverride != null) return propertySetterOverride;
    final platform = player.platform;
    if (platform is NativePlayer) {
      return platform.setProperty;
    }
    return null;
  }

  /// Resolves the optimal Windows `hwdec` mode given quality preset, active
  /// shaders/software filters, and player kernel (`'ijk'` = compat kernel).
  static String resolveHardwareDecoder({
    WindowsQualityPreset qualityPreset = WindowsQualityPreset.balancedHq,
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) {
    if (anime4kActive || softFilterActive || playerKernel == 'ijk') {
      return 'd3d11va-copy';
    }
    if (qualityPreset == WindowsQualityPreset.ecoCompat) {
      return 'd3d11va';
    }
    return preferZeroCopyD3d11 ? 'd3d11va' : 'auto-safe';
  }

  /// Convenience static loader for settings UI when no controller instance is
  /// mounted.
  static Future<WindowsQualityPreset> readSavedQualityPreset([
    SharedPreferences? prefs,
  ]) async {
    try {
      final sp = prefs ?? await SharedPreferences.getInstance();
      return WindowsQualityPreset.fromId(sp.getString(prefKeyQualityPreset));
    } catch (_) {
      return WindowsQualityPreset.balancedHq;
    }
  }

  static Future<AudioLoudnessPreset> readSavedLoudnessPreset([
    SharedPreferences? prefs,
  ]) async {
    try {
      final sp = prefs ?? await SharedPreferences.getInstance();
      return AudioLoudnessPreset.fromId(sp.getString(prefKeyLoudnessPreset));
    } catch (_) {
      return AudioLoudnessPreset.off;
    }
  }

  /// Loads persisted quality and loudness preferences on Windows.
  Future<void> loadSaved() async {
    if (!isPlatformSupported || !persistLocally || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      if (_disposed) return;
      final nextQuality = WindowsQualityPreset.fromId(
        sp.getString(prefKeyQualityPreset),
      );
      final nextLoudness = AudioLoudnessPreset.fromId(
        sp.getString(prefKeyLoudnessPreset),
      );
      final changed =
          nextQuality != _qualityPreset || nextLoudness != _loudnessPreset;
      _qualityPreset = nextQuality;
      _loudnessPreset = nextLoudness;
      _effectiveScale = nextQuality.baseScale;
      if (changed && !_disposed) {
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveQualityPreset(WindowsQualityPreset preset) async {
    if (!persistLocally || !isPlatformSupported || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setString(prefKeyQualityPreset, preset.id);
    } catch (_) {}
  }

  Future<void> _saveLoudnessPreset(AudioLoudnessPreset preset) async {
    if (!persistLocally || !isPlatformSupported || _disposed) return;
    try {
      final sp = _prefs ??= await SharedPreferences.getInstance();
      await sp.setString(prefKeyLoudnessPreset, preset.id);
    } catch (_) {}
  }

  /// Updates and persists the quality preset without requiring an active
  /// [Player] (e.g., from desktop Settings).
  Future<void> saveQualityPreset(WindowsQualityPreset next) async {
    if (_disposed) return;
    final changed = _qualityPreset != next;
    _qualityPreset = next;
    _effectiveScale = next.baseScale;
    await _saveQualityPreset(next);
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  /// Updates and persists the audio loudness preset without requiring an active
  /// [Player] (e.g., from desktop Settings).
  Future<void> saveLoudnessPreset(AudioLoudnessPreset next) async {
    if (_disposed) return;
    final changed = _loudnessPreset != next;
    _loudnessPreset = next;
    await _saveLoudnessPreset(next);
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  /// Applies both saved/current video quality and loudness presets to [player].
  Future<bool> applyAll(
    Player player, {
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    final qualityOk = await applyQualityPreset(
      player,
      _qualityPreset,
      persist: false,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    final loudnessOk = await applyLoudnessPreset(
      player,
      _loudnessPreset,
      persist: false,
    );
    return qualityOk && loudnessOk;
  }

  /// Synchronizes `hwdec` on [player] when Anime4K / soft filters / player
  /// kernel state changes without re-applying the full scaler table.
  Future<String?> syncHardwareDecoder(
    Player player, {
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return null;
    final setProp = _resolveSetter(player);
    if (setProp == null) return null;
    final target = resolveHardwareDecoder(
      qualityPreset: _qualityPreset,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    await _trySet(setProp, 'hwdec', target);
    _effectiveHwdec = target;
    return target;
  }

  /// Applies [next] quality preset properties to [player]'s `libmpv` backend
  /// with graceful fallbacks for older `libmpv` builds.
  Future<bool> applyQualityPreset(
    Player player,
    WindowsQualityPreset next, {
    bool persist = true,
    bool anime4kActive = false,
    bool softFilterActive = false,
    String playerKernel = 'exo',
    bool preferZeroCopyD3d11 = false,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    final gen = ++_qualityOpGen;
    _lastWarning = null;

    final hwdec = resolveHardwareDecoder(
      qualityPreset: next,
      anime4kActive: anime4kActive,
      softFilterActive: softFilterActive,
      playerKernel: playerKernel,
      preferZeroCopyD3d11: preferZeroCopyD3d11,
    );
    await _trySet(setProp, 'hwdec', hwdec);
    if (_disposed || gen != _qualityOpGen) return false;
    _effectiveHwdec = hwdec;

    switch (next) {
      case WindowsQualityPreset.ecoCompat:
        _effectiveScale = next.baseScale;
        _effectiveToneMapping = null;
        if (!anime4kActive) {
          await _trySet(setProp, 'scale', 'bilinear');
          if (_disposed || gen != _qualityOpGen) return false;
          await _trySet(setProp, 'cscale', 'bilinear');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        await _trySet(setProp, 'dscale', 'bilinear');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'no');
        await _trySet(setProp, 'linear-downscaling', 'no');
        await _trySet(setProp, 'sigmoid-upscaling', 'no');
        await _trySet(setProp, 'dither-depth', 'no');
        await _trySet(setProp, 'hdr-compute-peak', 'no');
        await _trySet(setProp, 'deband', 'no');
        await _trySet(setProp, 'gamut-mapping-mode', 'auto');
        await _trySet(setProp, 'tone-mapping', 'auto');
        await _trySet(setProp, 'target-colorspace-hint', 'no');
        break;

      case WindowsQualityPreset.balancedHq:
        _effectiveScale = next.baseScale;
        if (!anime4kActive) {
          await _trySet(setProp, 'scale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
          await _trySet(setProp, 'cscale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        await _trySet(setProp, 'dscale', 'mitchell');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'yes');
        await _trySet(setProp, 'linear-downscaling', 'yes');
        await _trySet(setProp, 'sigmoid-upscaling', 'yes');
        await _trySet(setProp, 'dither-depth', 'auto');
        await _trySet(setProp, 'hdr-compute-peak', 'yes');
        await _trySet(setProp, 'deband', 'no');
        await _trySet(setProp, 'gamut-mapping-mode', 'perceptual');
        if (_disposed || gen != _qualityOpGen) return false;
        _effectiveToneMapping = await _applyToneMappingFallback(setProp);
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'target-colorspace-hint', 'no');
        break;

      case WindowsQualityPreset.cinemaUltra:
        var appliedScale = 'ewa_lanczossharp';
        if (!anime4kActive) {
          final okEwa = await _trySet(setProp, 'scale', 'ewa_lanczossharp');
          if (_disposed || gen != _qualityOpGen) return false;
          if (!okEwa) {
            appliedScale = 'spline36';
            await _trySet(setProp, 'scale', 'spline36');
            if (_disposed || gen != _qualityOpGen) return false;
          }
          await _trySet(setProp, 'cscale', 'spline36');
          if (_disposed || gen != _qualityOpGen) return false;
        }
        _effectiveScale = appliedScale;
        await _trySet(setProp, 'dscale', 'mitchell');
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'correct-downscaling', 'yes');
        await _trySet(setProp, 'linear-downscaling', 'yes');
        await _trySet(setProp, 'sigmoid-upscaling', 'yes');
        await _trySet(setProp, 'dither-depth', 'auto');
        await _trySet(setProp, 'hdr-compute-peak', 'yes');
        await _trySet(setProp, 'hdr-peak-percentile', '99.995');
        await _trySet(setProp, 'deband', 'yes');
        await _trySet(setProp, 'gamut-mapping-mode', 'perceptual');
        if (_disposed || gen != _qualityOpGen) return false;
        _effectiveToneMapping = await _applyToneMappingFallback(setProp);
        if (_disposed || gen != _qualityOpGen) return false;
        await _trySet(setProp, 'target-colorspace-hint', 'yes');
        break;
    }

    if (_disposed || gen != _qualityOpGen) return false;
    _qualityPreset = next;
    if (persist) {
      await _saveQualityPreset(next);
      if (_disposed || gen != _qualityOpGen) return false;
    }
    notifyListeners();
    return true;
  }

  /// Returns true when an mpv log entry specifically indicates an audio-chain
  /// filter failure (never matching video-filter `vf` failures or shared
  /// generic `lavfi` / `ffmpeg` / `user_filter_wrapper` lines).
  static bool isAudioFilterFailureLog(PlayerLog entry) {
    return isAudioFilterFailureMessage(entry.text, prefix: entry.prefix);
  }

  /// Returns true when an mpv log or error line explicitly indicates an audio
  /// filter initialization/runtime failure (excluding video-only filter errors
  /// such as `vf: Disabling filter ...` or generic `lavfi` graph errors).
  static bool isAudioFilterFailureMessage(String text, {String? prefix}) {
    final normalizedPrefix = (prefix ?? '').trim().toLowerCase();
    final lower = text.toLowerCase();
    if (normalizedPrefix == 'vf' ||
        normalizedPrefix == 'vo' ||
        normalizedPrefix == 'vd' ||
        normalizedPrefix == 'sub') {
      return false;
    }
    if (lower.startsWith('vf:') ||
        lower.startsWith('[vf/') ||
        lower.startsWith('vo:') ||
        lower.startsWith('[vo/')) {
      return false;
    }
    if (lower.contains('audio filter initialized failed') ||
        lower.contains('failed to initialize audio filter') ||
        lower.contains('creating audio filter')) {
      return true;
    }
    if (lower.contains('disabling filter')) {
      return normalizedPrefix == 'af' ||
          normalizedPrefix == 'ao' ||
          normalizedPrefix == 'ad' ||
          lower.startsWith('af:') ||
          lower.startsWith('[af/') ||
          lower.contains('audio filter');
    }
    return false;
  }

  void _cancelTrackSubscription() {
    final prev = _trackSub;
    _trackSub = null;
    if (prev != null) {
      unawaited(prev.cancel());
    }
  }

  void _subscribePlayerTrack(Player player) {
    _cancelTrackSubscription();
    if (_disposed ||
        _audioFilterRecoverySuspended ||
        !identical(_attachedPlayer, player)) {
      return;
    }
    final subscribedSessionGen = _recoverySessionGen;
    try {
      _trackSub = player.stream.track.listen((track) {
        if (_disposed ||
            _audioFilterRecoverySuspended ||
            subscribedSessionGen != _recoverySessionGen ||
            !identical(_attachedPlayer, player)) {
          return;
        }
        final id = track.audio.id.trim();
        if (id.isNotEmpty && id != 'no' && id != 'auto') {
          _lastActiveAudioTrackId = id;
        }
      });
    } catch (_) {}
  }

  void _cancelLogSubscription() {
    final prev = _logSub;
    _logSub = null;
    if (prev != null) {
      unawaited(prev.cancel());
    }
  }

  void _subscribePlayerLog(Player player) {
    _cancelLogSubscription();
    if (_disposed ||
        _audioFilterRecoverySuspended ||
        !identical(_attachedPlayer, player)) {
      return;
    }
    final subscribedSessionGen = _recoverySessionGen;
    try {
      _logSub = player.stream.log.listen((entry) {
        if (_disposed ||
            _audioFilterRecoverySuspended ||
            subscribedSessionGen != _recoverySessionGen ||
            !identical(_attachedPlayer, player)) {
          return;
        }
        if (_loudnessPreset == AudioLoudnessPreset.off &&
            _activeAppliedAudioFilter.isEmpty) {
          return;
        }
        if (!isAudioFilterFailureLog(entry)) return;
        final combined = '${entry.prefix}: ${entry.text}';
        _pendingAudioRecoveryTimer?.cancel();
        _pendingAudioRecoveryTimer = null;
        unawaited(
          handleRuntimeAudioFilterFailure(
            player,
            reason: combined,
            immediate: true,
            expectedRecoveryGen: subscribedSessionGen,
          ),
        );
      });
    } catch (_) {}
  }

  /// Attaches runtime listeners to [player] so active audio track selection is
  /// tracked and any asynchronous mpv audio-filter initialization failure
  /// immediately clears `af`, restores original sound on the active movie, and
  /// synchronizes UI state back to [AudioLoudnessPreset.off].
  void attachPlayer(
    Player player, {
    VoidCallback? onLoudnessFallbackToOff,
  }) {
    if (_disposed) return;
    detachPlayer();
    if (!isAvailableForPlayer(player)) return;
    _wasAttached = true;
    _attachedPlayer = player;
    _audioFilterRecoverySuspended = false;
    _onLoudnessFallbackToOff = onLoudnessFallbackToOff;
    try {
      final currentId = player.state.track.audio.id.trim();
      if (currentId.isNotEmpty && currentId != 'no' && currentId != 'auto') {
        _lastActiveAudioTrackId = currentId;
      }
    } catch (_) {}
    _subscribePlayerTrack(player);
    _subscribePlayerLog(player);
  }

  /// Detaches any runtime audio-filter monitoring subscriptions and invalidates
  /// any in-flight or debounced failure recovery from the prior player/engine.
  void detachPlayer() {
    _recoverySessionGen++;
    _activeRecoveryTaskId = null;
    _activeRecoverySessionGen = null;
    _activeRecoveryPlayer = null;
    _audioFilterRecoverySuspended = false;
    _pendingAudioRecoveryTimer?.cancel();
    _pendingAudioRecoveryTimer = null;
    _cancelTrackSubscription();
    _cancelLogSubscription();
    _attachedPlayer = null;
    _onLoudnessFallbackToOff = null;
  }

  /// Clears per-media remembered audio track ID, drops already-queued logs and
  /// track-selection events from the outgoing media session, and invalidates
  /// any pending or in-flight failure recovery from the previous episode/media
  /// so delayed events never overwrite or block the newly opened session.
  void onMediaChanged({bool suspendRecoveryUntilOpen = false}) {
    _recoverySessionGen++;
    _activeRecoveryTaskId = null;
    _activeRecoverySessionGen = null;
    _activeRecoveryPlayer = null;
    _pendingAudioRecoveryTimer?.cancel();
    _pendingAudioRecoveryTimer = null;
    _lastActiveAudioTrackId = null;
    _cancelTrackSubscription();
    _cancelLogSubscription();
    if (suspendRecoveryUntilOpen) {
      _audioFilterRecoverySuspended = true;
    } else if (!_audioFilterRecoverySuspended && _attachedPlayer != null) {
      _subscribePlayerTrack(_attachedPlayer!);
      _subscribePlayerLog(_attachedPlayer!);
    }
  }

  /// Re-enables runtime audio-filter failure recovery right before opening the
  /// next media item after [onMediaChanged] suspended it during teardown,
  /// starting fresh log and track subscriptions so queued events from the
  /// outgoing media cannot leak into the new session.
  void resumeAudioFilterRecovery() {
    if (_disposed) return;
    _audioFilterRecoverySuspended = false;
    if (_attachedPlayer != null) {
      _subscribePlayerTrack(_attachedPlayer!);
      _subscribePlayerLog(_attachedPlayer!);
    }
  }

  String _resolveRestoreAudioTrackId(Player player) {
    String? candidate;
    try {
      final currentId = player.state.track.audio.id.trim();
      if (currentId.isNotEmpty && currentId != 'no' && currentId != 'auto') {
        candidate = currentId;
      }
    } catch (_) {}
    candidate ??= _lastActiveAudioTrackId;
    if (candidate == null || candidate.isEmpty) {
      return 'auto';
    }
    try {
      final audioTracks = player.state.tracks.audio;
      if (audioTracks.isNotEmpty) {
        final exists = audioTracks.any((t) => t.id == candidate);
        if (!exists) {
          return 'auto';
        }
      }
    } catch (_) {}
    return candidate;
  }

  /// Recovers active audio playback when `libmpv` reports an asynchronous
  /// audio-filter initialization failure: strips `af`, re-selects the active
  /// audio track (`aid=no` -> `aid=<track|auto>`), updates preset state to
  /// [AudioLoudnessPreset.off], persists `off`, and notifies listeners/UI.
  Future<bool> handleRuntimeAudioFilterFailure(
    Player player, {
    String reason = '',
    bool immediate = true,
    int? expectedRecoveryGen,
  }) async {
    if (_disposed ||
        _audioFilterRecoverySuspended ||
        !isAvailableForPlayer(player)) {
      return false;
    }
    if (_wasAttached && !identical(_attachedPlayer, player)) {
      return false;
    }
    final recoveryGen = expectedRecoveryGen ?? _recoverySessionGen;
    if (recoveryGen != _recoverySessionGen) {
      return false;
    }
    if (_loudnessPreset == AudioLoudnessPreset.off &&
        _activeAppliedAudioFilter.isEmpty) {
      return false;
    }
    if (_activeRecoveryTaskId != null &&
        _activeRecoverySessionGen == recoveryGen &&
        identical(_activeRecoveryPlayer, player)) {
      return false;
    }
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;

    _pendingAudioRecoveryTimer?.cancel();
    _pendingAudioRecoveryTimer = null;
    final taskId = ++_recoveryTaskSeq;
    _activeRecoveryTaskId = taskId;
    _activeRecoverySessionGen = recoveryGen;
    _activeRecoveryPlayer = player;
    final gen = ++_loudnessOpGen;
    bool isStale() =>
        _disposed ||
        _audioFilterRecoverySuspended ||
        _activeRecoveryTaskId != taskId ||
        gen != _loudnessOpGen ||
        recoveryGen != _recoverySessionGen ||
        (_wasAttached && !identical(_attachedPlayer, player));
    try {
      final settleDelay = recoverySettleDelayOverride ??
          (propertySetterOverride != null
              ? Duration.zero
              : (immediate
                  ? const Duration(milliseconds: 60)
                  : Duration.zero));
      if (settleDelay > Duration.zero) {
        await Future<void>.delayed(settleDelay);
        if (isStale()) return false;
      }

      final restoreTrackId = _resolveRestoreAudioTrackId(player);
      await _trySet(setProp, 'af', '');
      if (isStale()) return false;
      await _trySet(setProp, 'volume-max', AudioLoudnessPreset.off.volumeMax);
      if (isStale()) return false;
      // Force mpv to re-open the audio output chain after `deselect track`.
      await _trySet(setProp, 'aid', 'no');
      if (isStale()) return false;
      await _trySet(setProp, 'aid', restoreTrackId);
      if (isStale()) return false;

      _activeAppliedAudioFilter = '';
      _loudnessPreset = AudioLoudnessPreset.off;
      _lastWarning = reason.trim().isEmpty
          ? audioFallbackWarningZh
          : audioFallbackWarningZh;
      if (persistLocally) {
        await _saveLoudnessPreset(AudioLoudnessPreset.off);
        if (isStale()) return false;
      }
      notifyListeners();
      _onLoudnessFallbackToOff?.call();
      return true;
    } finally {
      if (_activeRecoveryTaskId == taskId) {
        _activeRecoveryTaskId = null;
        _activeRecoverySessionGen = null;
        _activeRecoveryPlayer = null;
      }
    }
  }

  /// Applies [next] audio vocal enhancement preset to [player].
  Future<bool> applyLoudnessPreset(
    Player player,
    AudioLoudnessPreset next, {
    bool persist = true,
  }) async {
    if (_disposed || !isAvailableForPlayer(player)) return false;
    final setProp = _resolveSetter(player);
    if (setProp == null) return false;
    _pendingAudioRecoveryTimer?.cancel();
    _pendingAudioRecoveryTimer = null;
    _activeRecoveryTaskId = null;
    _activeRecoverySessionGen = null;
    _activeRecoveryPlayer = null;
    final gen = ++_loudnessOpGen;

    await _trySet(setProp, 'volume-max', next.volumeMax);
    if (_disposed || gen != _loudnessOpGen) return false;

    var appliedFilter = '';
    var effectivePreset = next;
    var succeeded = true;

    if (next == AudioLoudnessPreset.off) {
      await _trySet(setProp, 'af', '');
      if (_disposed || gen != _loudnessOpGen) return false;
      _lastWarning = null;
    } else {
      final primaryFilter = debugAudioFilterOverride ?? next.audioFilter;
      final ok = await _trySet(setProp, 'af', primaryFilter);
      if (_disposed || gen != _loudnessOpGen) return false;
      if (ok) {
        appliedFilter = primaryFilter;
        _lastWarning = null;
      } else {
        var fallbackOk = false;
        if (primaryFilter != fallbackAudioFilter) {
          fallbackOk = await _trySet(setProp, 'af', fallbackAudioFilter);
          if (_disposed || gen != _loudnessOpGen) return false;
        }
        if (fallbackOk) {
          appliedFilter = fallbackAudioFilter;
        } else {
          await _trySet(setProp, 'af', '');
          if (_disposed || gen != _loudnessOpGen) return false;
          appliedFilter = '';
          effectivePreset = AudioLoudnessPreset.off;
          succeeded = false;
          _lastWarning = audioFallbackWarningZh;
        }
      }
    }

    if (_disposed || gen != _loudnessOpGen) return false;
    _activeAppliedAudioFilter = appliedFilter;
    _loudnessPreset = effectivePreset;
    if (persist || !succeeded) {
      await _saveLoudnessPreset(effectivePreset);
      if (_disposed || gen != _loudnessOpGen) return false;
    }
    notifyListeners();
    if (!succeeded) {
      _onLoudnessFallbackToOff?.call();
    }
    return succeeded;
  }

  Future<String?> _applyToneMappingFallback(
    WindowsMpvPropertySetter setProp,
  ) async {
    for (final candidate in toneMappingFallbackChain) {
      if (_disposed) return null;
      final ok = await _trySet(setProp, 'tone-mapping', candidate);
      if (ok) return candidate;
    }
    return null;
  }

  Future<bool> _trySet(
    WindowsMpvPropertySetter setProp,
    String key,
    String value,
  ) async {
    try {
      await setProp(key, value);
      return true;
    } catch (e) {
      _lastWarning = '$key=$value: $e';
      return false;
    }
  }

  @override
  void dispose() {
    _qualityOpGen++;
    _loudnessOpGen++;
    _disposed = true;
    detachPlayer();
    super.dispose();
  }
}

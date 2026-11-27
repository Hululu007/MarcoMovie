// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:media_kit/media_kit.dart';

import 'ios_avplayer_controller.dart';
import 'mdk_platform_player.dart';

typedef MpvPropertySetter = Future<void> Function(String key, String value);

/// Device RAM tier used to lift the iOS libmpv 33 MiB buffer bottleneck.
enum IosRamBufferTier {
  standardUnder6Gb(
    maxBytes: 67108864, // 64 MiB
    maxBackBytes: 16777216, // 16 MiB
    readaheadSecs: 30,
  ),
  high6GbPlusDefault(
    maxBytes: 134217728, // 128 MiB
    maxBackBytes: 33554432, // 32 MiB
    readaheadSecs: 60,
  ),
  high6GbPlusLarge(
    maxBytes: 268435456, // 256 MiB
    maxBackBytes: 67108864, // 64 MiB
    readaheadSecs: 90,
  ),
  liveLean(
    maxBytes: 16777216, // 16 MiB
    maxBackBytes: 4194304, // 4 MiB
    readaheadSecs: 5,
  );

  final int maxBytes;
  final int maxBackBytes;
  final int readaheadSecs;

  const IosRamBufferTier({
    required this.maxBytes,
    required this.maxBackBytes,
    required this.readaheadSecs,
  });
}

/// HDR tone-mapping strategy for iOS/iPadOS libmpv XDR/EDR displays.
enum IosHdrToneMappingMode {
  auto(
    id: 'auto',
    labelZh: '自动 (BT.2390 动态)',
    mpvToneMapping: 'bt.2390',
    computePeak: 'yes',
  ),
  bt2390(
    id: 'bt.2390',
    labelZh: 'BT.2390 电影动态映射',
    mpvToneMapping: 'bt.2390',
    computePeak: 'yes',
  ),
  bt2446a(
    id: 'bt.2446a',
    labelZh: 'BT.2446a 高亮保留',
    mpvToneMapping: 'bt.2446a',
    computePeak: 'yes',
  ),
  hable(
    id: 'hable',
    labelZh: 'Hable 柔和映射',
    mpvToneMapping: 'hable',
    computePeak: 'yes',
  ),
  clip(
    id: 'clip',
    labelZh: '原生高光直出 (Clip)',
    mpvToneMapping: 'clip',
    computePeak: 'no',
  );

  final String id;
  final String labelZh;
  final String mpvToneMapping;
  final String computePeak;

  const IosHdrToneMappingMode({
    required this.id,
    required this.labelZh,
    required this.mpvToneMapping,
    required this.computePeak,
  });

  static IosHdrToneMappingMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in IosHdrToneMappingMode.values) {
      if (mode.id == normalized) return mode;
    }
    return IosHdrToneMappingMode.auto;
  }
}

/// Cross-platform 4-tier dialogue loudness and dynamic-range normalizer
/// resolving quiet 5.1/7.1 -> stereo dialogue downmixes.
enum VocalLoudnessPreset {
  off(
    id: 'off',
    labelZh: '关闭',
    shortLabelZh: '关闭',
    descriptionZh: '保持原始音频动态范围（100% 音量上限）',
    volumeMax: 100,
    audioFilter: '',
  ),
  light(
    id: 'light',
    labelZh: '轻度',
    shortLabelZh: '轻度',
    descriptionZh: '温和提升微弱人声（上限 150%，保留影院动态）',
    volumeMax: 150,
    audioFilter: 'lavfi=[dynaudnorm=f=150:g=15:p=0.90:m=3.0]',
  ),
  standard(
    id: 'standard',
    labelZh: '标准',
    shortLabelZh: '标准',
    descriptionZh: '均衡夜间对白响度（上限 200%，抑制爆炸声刺耳）',
    volumeMax: 200,
    audioFilter: 'lavfi=[dynaudnorm=f=150:g=15:p=0.95:m=6.0]',
  ),
  cinemaVocal(
    id: 'cinema_vocal',
    labelZh: '影院人声',
    shortLabelZh: '影院人声',
    descriptionZh: '强力增强 1–3kHz 人声对白，专治 5.1/7.1 小声片源',
    volumeMax: 200,
    audioFilter:
        'lavfi=[highpass=f=90,equalizer=f=1800:t=q:w=1.2:g=3.5,dynaudnorm=f=120:g=11:p=0.95:m=8.0]',
  );

  final String id;
  final String labelZh;
  final String shortLabelZh;
  final String descriptionZh;
  final int volumeMax;
  final String audioFilter;

  const VocalLoudnessPreset({
    required this.id,
    required this.labelZh,
    required this.shortLabelZh,
    required this.descriptionZh,
    required this.volumeMax,
    required this.audioFilter,
  });

  static VocalLoudnessPreset fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final preset in VocalLoudnessPreset.values) {
      if (preset.id == normalized) return preset;
    }
    return VocalLoudnessPreset.off;
  }
}

/// Builds and applies iOS-tuned 4K/HDR, RAM-tiered demuxer buffering,
/// frame-accurate seeking, ASS scaling, and 4-tier vocal loudness properties
/// for `libmpv` (`media_kit` [NativePlayer]).
class IosMpvProfile {
  /// iOS `ProcessInfo.physicalMemory` reports usable physical RAM slightly below
  /// the marketing 6 GB figure (~5.5–5.9 GiB due to kernel carveout), whereas
  /// 4 GB devices report ~3.6–3.9 GiB. `5.2 GiB` cleanly separates 6 GB+ vs <6 GB.
  static const int highRamPhysicalBytesThreshold = 5583457485; // ~5.2 GiB

  static const String prefKeyEngineMode = 'ios_player_engine_mode';
  static const String prefKeyHdrToneMapping = 'ios_mpv_hdr_tone_mapping';
  static const String prefKeyVocalLoudness = 'vocal_loudness_preset';
  static const String prefKeyLargeBuffer = 'ios_mpv_large_buffer';

  static bool isHighRamDevice(int? physicalMemoryBytes) {
    if (physicalMemoryBytes == null || physicalMemoryBytes <= 0) return false;
    return physicalMemoryBytes >= highRamPhysicalBytesThreshold;
  }

  static final RegExp _dolbyVisionTokenRe = RegExp(
    r'(?:杜比视界|Dolby[\s._\-]*Vision|\bDoVi\b|\bdvhe\b|\bdvh1\b|(?:^|[\s._\-\[\(【（])DV(?=$|[\s._\-\]\)】）]))',
    caseSensitive: false,
  );

  static final RegExp _uhd10BitTokenRe = RegExp(
    r'(?:\b2160[pP]\b|\b4K\b|HDR10\+?|(?<!\w)HDR(?!\w)|\b10[\s._\-]*bit\b|\bRemux\b|原盘)',
    caseSensitive: false,
  );

  /// Detects whether stream/file metadata indicates Dolby Vision (`Profile 5 / 7 / 8`
  /// `ICtCp` / `dovi`) where iOS OpenGL ES `libmpv` (built without `libplacebo`)
  /// would render green/purple unless routed to Apple `AVPlayer` or Metal `MDK`.
  static bool isLikelyDolbyVisionMedia({
    String url = '',
    String episodeName = '',
    String lineName = '',
    String videoTitle = '',
    String videoRemarks = '',
  }) {
    final combined = '$episodeName $lineName $videoTitle $videoRemarks $url';
    return _dolbyVisionTokenRe.hasMatch(combined);
  }

  /// Detects 4K / 10-bit HDR / Dolby Vision streams that benefit from Metal +
  /// zero-copy `VideoToolbox` (`MDK`) when `AVPlayer` cannot open the container
  /// (e.g. `.mkv` / `.webm` / `.ts` netdisk originals).
  static bool prefersIosMetalMdkWhenAvPlayerUnsupported({
    String url = '',
    String episodeName = '',
    String lineName = '',
    String videoTitle = '',
    String videoRemarks = '',
  }) {
    if (isLikelyDolbyVisionMedia(
      url: url,
      episodeName: episodeName,
      lineName: lineName,
      videoTitle: videoTitle,
      videoRemarks: videoRemarks,
    )) {
      return true;
    }
    final combined = '$episodeName $lineName $videoTitle $videoRemarks $url';
    if (_uhd10BitTokenRe.hasMatch(combined)) return true;
    final lowerUrl = url.toLowerCase();
    final lowerEp = episodeName.toLowerCase();
    return lowerUrl.contains('.mkv') || lowerEp.endsWith('.mkv');
  }

  /// Pure policy predicate deciding whether iOS `libmpv` should run in
  /// low-power thermal mode (`hdr-compute-peak=no`, `dither-depth=no`,
  /// `video-sync=audio`). Activates as soon as thermal pressure reaches `.fair`
  /// (before `.serious` overheating builds up) or on legacy iOS < 16.
  static bool shouldUseLowPowerThermalMode({
    IosThermalState? avThermalState,
    bool bridgeThermalElevated = false,
    int iosMajorVersion = 0,
  }) {
    if (avThermalState != null && avThermalState.isElevated) return true;
    if (bridgeThermalElevated) return true;
    if (iosMajorVersion > 0 && iosMajorVersion < 16) return true;
    return false;
  }

  /// Pure policy predicate deciding whether a playback position tick should
  /// trigger a full `PlayerScreen.setState()` rebuild.
  ///
  /// When the player HUD is hidden (`controlsVisible == false` and
  /// `slimBarVisible == false`), returns `false` so steady-state movie playback
  /// incurs **zero** widget-tree rebuilds per second (`DanmuLayer` updates via
  /// its dedicated `ValueNotifier<int>` without `setState`).
  static bool shouldRebuildPositionUi({
    required bool isIos,
    required bool controlsVisible,
    required bool screenLocked,
    required bool slimBarVisible,
    required bool isPipActive,
    required bool playing,
    required int nowMs,
    required int lastUpdateMs,
    required int nextPositionMs,
    required int lastRenderedPositionMs,
    bool iosThermalElevated = false,
  }) {
    if (isPipActive) return false;
    final visibleInteractiveControls = controlsVisible && !screenLocked;
    if (!visibleInteractiveControls && !slimBarVisible) {
      return false;
    }
    if (!playing) return true;
    final posDeltaMs = (nextPositionMs - lastRenderedPositionMs).abs();
    if (visibleInteractiveControls) {
      if ((nextPositionMs ~/ 1000) != (lastRenderedPositionMs ~/ 1000)) {
        return true;
      }
      final minIntervalMs = (isIos && iosThermalElevated) ? 500 : 250;
      if (posDeltaMs >= minIntervalMs) return true;
      return (nowMs - lastUpdateMs) >= minIntervalMs;
    }
    // Only the 2px bottom SlimProgressBar is visible: on iOS 1 Hz (or 2s under
    // thermal elevation) is visually indistinguishable while cutting full
    // PlayerScreen rebuilds by 75%–88%.
    if (!isIos) {
      return (nowMs - lastUpdateMs) >= 250;
    }
    if (posDeltaMs >= 5000) return true;
    final slimIntervalMs = iosThermalElevated ? 2000 : 1000;
    return (nowMs - lastUpdateMs) >= slimIntervalMs;
  }

  static IosRamBufferTier resolveBufferTier({
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
  }) {
    if (isLive) return IosRamBufferTier.liveLean;
    if (isHighRamDevice(physicalMemoryBytes)) {
      return largeBuffer
          ? IosRamBufferTier.high6GbPlusLarge
          : IosRamBufferTier.high6GbPlusDefault;
    }
    return IosRamBufferTier.standardUnder6Gb;
  }

  /// Generates the full map of libmpv properties for iOS playback.
  static Map<String, String> buildMpvProperties({
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
    IosHdrToneMappingMode hdrToneMapping = IosHdrToneMappingMode.auto,
    VocalLoudnessPreset vocalLoudness = VocalLoudnessPreset.off,
    String hwdec = 'videotoolbox',
    bool lowPowerThermalMode = false,
  }) {
    final tier = resolveBufferTier(
      physicalMemoryBytes: physicalMemoryBytes,
      largeBuffer: largeBuffer,
      isLive: isLive,
    );

    return <String, String>{
      'cache': 'yes',
      'cache-on-disk': 'no',
      'hwdec': hwdec,
      // Critical on iOS OpenGL ES (`EAGLContext`): overrides media-kit's
      // 10-bit -> 33 MB `BGRA` fallback so `VTDecompressionSession` outputs
      // hardware-scaled planar `NV12` zero-copy at full 60fps instead of
      // stalling in ~8fps slow motion on 4K 10-bit HEVC streams.
      'hwdec-image-format': 'nv12',
      'vd-lavc-threads': '0',
      'vd-lavc-dr': 'yes',
      'framedrop': 'vo',
      'demuxer-max-bytes': '${tier.maxBytes}',
      'demuxer-max-back-bytes': '${tier.maxBackBytes}',
      'demuxer-readahead-secs': '${tier.readaheadSecs}',
      'hr-seek': 'yes',
      'sub-ass-override': 'scale',
      'tone-mapping': hdrToneMapping.mpvToneMapping,
      'hdr-compute-peak': lowPowerThermalMode ? 'no' : hdrToneMapping.computePeak,
      'gamut-mapping-mode': 'perceptual',
      'dither-depth': lowPowerThermalMode ? 'no' : 'auto',
      if (lowPowerThermalMode) 'video-sync': 'audio',
      'target-colorspace-hint': 'yes',
      ...buildVocalLoudnessProperties(vocalLoudness),
    };
  }

  /// Generates cross-platform `volume-max` and `af` properties for [preset].
  static Map<String, String> buildVocalLoudnessProperties(
    VocalLoudnessPreset preset,
  ) {
    return <String, String>{
      'volume-max': '${preset.volumeMax}',
      'af': preset.audioFilter,
    };
  }

  /// Applies the full iOS MPV profile to [player] safely.
  static Future<void> applyToPlayer(
    Player player, {
    int? physicalMemoryBytes,
    bool largeBuffer = false,
    bool isLive = false,
    IosHdrToneMappingMode hdrToneMapping = IosHdrToneMappingMode.auto,
    VocalLoudnessPreset vocalLoudness = VocalLoudnessPreset.off,
    String hwdec = 'videotoolbox',
    bool lowPowerThermalMode = false,
    MpvPropertySetter? propertySetterOverride,
  }) async {
    final setter = propertySetterOverride ?? _resolveSetter(player);
    if (setter == null) return;
    final props = buildMpvProperties(
      physicalMemoryBytes: physicalMemoryBytes,
      largeBuffer: largeBuffer,
      isLive: isLive,
      hdrToneMapping: hdrToneMapping,
      vocalLoudness: vocalLoudness,
      hwdec: hwdec,
      lowPowerThermalMode: lowPowerThermalMode,
    );
    for (final entry in props.entries) {
      try {
        await setter(entry.key, entry.value);
      } catch (_) {}
    }
  }

  /// Hot-applies vocal loudness gain without restarting playback.
  static Future<void> applyVocalLoudness(
    Player player,
    VocalLoudnessPreset preset, {
    MpvPropertySetter? propertySetterOverride,
  }) async {
    final setter = propertySetterOverride ?? _resolveSetter(player);
    if (setter == null) return;
    final props = buildVocalLoudnessProperties(preset);
    for (final entry in props.entries) {
      try {
        await setter(entry.key, entry.value);
      } catch (_) {}
    }
  }

  static MpvPropertySetter? _resolveSetter(Player player) {
    final platform = player.platform;
    if (platform is NativePlayer) {
      return platform.setProperty;
    }
    if (platform is MdkPlatformPlayer) {
      return platform.setProperty;
    }
    return null;
  }
}

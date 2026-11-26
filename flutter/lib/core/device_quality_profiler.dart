import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ios_avplayer_controller.dart';
import 'ios_mpv_profile.dart';
import 'ohos_runtime.dart';
import 'storage_service.dart';

enum DeviceHardwareTier {
  flagship,
  balanced,
  efficiency,
}

extension DeviceHardwareTierLabel on DeviceHardwareTier {
  String get labelZh => switch (this) {
        DeviceHardwareTier.flagship => '旗舰性能档',
        DeviceHardwareTier.balanced => '均衡高清档',
        DeviceHardwareTier.efficiency => '省电流畅档',
      };
}

class DeviceHardwareSnapshot {
  final String machineIdentifier;
  final String modelName;
  final int physicalMemoryBytes;
  final int processorCount;
  final bool supportsHdrDisplay;
  final double potentialEdrHeadroom;
  final String osVersion;
  final bool isPad;
  final bool lowPowerMode;
  final IosThermalState thermalState;

  const DeviceHardwareSnapshot({
    this.machineIdentifier = '',
    this.modelName = '当前设备',
    this.physicalMemoryBytes = 0,
    this.processorCount = 0,
    this.supportsHdrDisplay = false,
    this.potentialEdrHeadroom = 1.0,
    this.osVersion = '',
    this.isPad = false,
    this.lowPowerMode = false,
    this.thermalState = IosThermalState.nominal,
  });

  double get memoryGb =>
      physicalMemoryBytes > 0 ? physicalMemoryBytes / (1024 * 1024 * 1024) : 0.0;

  String get memoryLabel {
    if (physicalMemoryBytes <= 0) return '';
    final gb = memoryGb;
    if (gb >= 15.0) return '16 GB';
    if (gb >= 11.0) return '12 GB';
    if (gb >= 7.2) return '8 GB';
    if (gb >= 5.3) return '6 GB';
    if (gb >= 3.5) return '4 GB';
    if (gb >= 2.6) return '3 GB';
    return '${gb.toStringAsFixed(1)} GB';
  }
}

class DeviceQualityRecommendation {
  final DeviceHardwareSnapshot hardware;
  final DeviceHardwareTier tier;
  final String iosPlaybackEngineMode;
  final String iosHdrToneMappingMode;
  final bool iosAnime4kLightweightEnabled;
  final bool iosLargeBufferEnabled;
  final String preferredQuality;
  final String defaultAspectMode;
  final String playerKernel;
  final int mediaDiskCacheLimitMb;

  const DeviceQualityRecommendation({
    required this.hardware,
    required this.tier,
    required this.iosPlaybackEngineMode,
    required this.iosHdrToneMappingMode,
    required this.iosAnime4kLightweightEnabled,
    required this.iosLargeBufferEnabled,
    required this.preferredQuality,
    required this.defaultAspectMode,
    required this.playerKernel,
    required this.mediaDiskCacheLimitMb,
  });

  String get hardwareSummaryZh {
    final parts = <String>[hardware.modelName];
    if (hardware.memoryLabel.isNotEmpty) {
      parts.add('${hardware.memoryLabel} 内存');
    }
    if (hardware.processorCount > 0) {
      parts.add('${hardware.processorCount} 核');
    }
    if (hardware.potentialEdrHeadroom >= 1.5) {
      parts.add('XDR/HDR 屏');
    } else if (hardware.supportsHdrDisplay) {
      parts.add('广色域屏');
    }
    if (hardware.lowPowerMode) {
      parts.add('低电量模式');
    }
    return parts.join(' · ');
  }

  String get detailSummaryZh {
    final hdr = IosHdrToneMappingMode.fromId(iosHdrToneMappingMode).labelZh;
    final buf = iosLargeBufferEnabled ? '256 MB 大缓冲' : '128 MB 均衡缓冲';
    final sr = iosAnime4kLightweightEnabled ? '开启轻量超分' : '关闭超分省电';
    final qual = preferredQuality == '4k_netdisk' ? '4K 原画优先' : '1080P 流畅优先';
    return '${tier.labelZh}：$qual · $hdr · $buf · $sr';
  }
}

/// Detects local iOS / iPadOS / desktop hardware capabilities (SoC generation,
/// RAM, core count, XDR/EDR display headroom, Low Power & Thermal pressure) and
/// picks the optimal playback, HDR, buffer, and super-resolution preset.
class DeviceQualityProfiler {
  @visibleForTesting
  static DeviceHardwareSnapshot? testSnapshotOverride;

  static Future<DeviceHardwareSnapshot> detect({
    MethodChannel? channelOverride,
  }) async {
    if (testSnapshotOverride != null) return testSnapshotOverride!;
    if (!kIsWeb &&
        !OhosRuntime.isOhos &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final channel = channelOverride ?? IosAvPlayerController.defaultChannel;
        final map = await channel.invokeMapMethod<String, dynamic>('getTelemetry');
        if (map != null && map.isNotEmpty) {
          final machineId = (map['machineIdentifier'] ?? '').toString().trim();
          final isPad = map['isPad'] == true;
          final memBytes = (map['physicalMemoryBytes'] as num?)?.toInt() ?? 0;
          final cores = (map['processorCount'] as num?)?.toInt() ?? 0;
          final headroom = (map['potentialEdrHeadroom'] as num?)?.toDouble() ?? 1.0;
          final supportsHdr = map['supportsHdrDisplay'] == true || headroom > 1.05;
          final osVer = (map['osVersion'] ?? '').toString().trim();
          final lowPower = map['lowPowerMode'] == true;
          final thermal = IosThermalState.fromWire(
            map['thermalState'] ?? map['thermalStateCode'],
          );
          return DeviceHardwareSnapshot(
            machineIdentifier: machineId,
            modelName: friendlyModelName(machineId, isPad: isPad),
            physicalMemoryBytes: memBytes,
            processorCount: cores,
            supportsHdrDisplay: supportsHdr,
            potentialEdrHeadroom: headroom,
            osVersion: osVer,
            isPad: isPad,
            lowPowerMode: lowPower,
            thermalState: thermal,
          );
        }
      } catch (_) {}
    }
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    return DeviceHardwareSnapshot(
      machineIdentifier: defaultTargetPlatform.name,
      modelName: isDesktop ? '桌面高性能设备' : 'iOS 设备',
      physicalMemoryBytes: isDesktop ? 8 * 1024 * 1024 * 1024 : 4 * 1024 * 1024 * 1024,
      processorCount: isDesktop ? 8 : 6,
      supportsHdrDisplay: isDesktop,
      potentialEdrHeadroom: isDesktop ? 1.6 : 1.2,
    );
  }

  static String friendlyModelName(String machineId, {bool isPad = false}) {
    final id = machineId.trim();
    if (id.isEmpty || id == 'arm64' || id == 'x86_64') {
      return isPad ? 'iPad' : 'iPhone';
    }
    const known = <String, String>{
      'iPhone18,1': 'iPhone 17 Pro',
      'iPhone18,2': 'iPhone 17 Pro Max',
      'iPhone18,3': 'iPhone 17',
      'iPhone18,4': 'iPhone 17 Air',
      'iPhone17,1': 'iPhone 16 Pro',
      'iPhone17,2': 'iPhone 16 Pro Max',
      'iPhone17,3': 'iPhone 16',
      'iPhone17,4': 'iPhone 16 Plus',
      'iPhone17,5': 'iPhone 16e',
      'iPhone16,1': 'iPhone 15 Pro',
      'iPhone16,2': 'iPhone 15 Pro Max',
      'iPhone15,4': 'iPhone 15',
      'iPhone15,5': 'iPhone 15 Plus',
      'iPhone15,2': 'iPhone 14 Pro',
      'iPhone15,3': 'iPhone 14 Pro Max',
      'iPhone14,7': 'iPhone 14',
      'iPhone14,8': 'iPhone 14 Plus',
      'iPhone14,2': 'iPhone 13 Pro',
      'iPhone14,3': 'iPhone 13 Pro Max',
      'iPhone14,5': 'iPhone 13',
      'iPhone14,4': 'iPhone 13 mini',
      'iPhone14,6': 'iPhone SE (3rd)',
      'iPhone13,3': 'iPhone 12 Pro',
      'iPhone13,4': 'iPhone 12 Pro Max',
      'iPhone13,2': 'iPhone 12',
      'iPhone13,1': 'iPhone 12 mini',
      'iPhone12,1': 'iPhone 11',
      'iPhone12,3': 'iPhone 11 Pro',
      'iPhone12,5': 'iPhone 11 Pro Max',
      'iPhone12,8': 'iPhone SE (2nd)',
      'iPhone11,2': 'iPhone XS',
      'iPhone11,6': 'iPhone XS Max',
      'iPhone11,8': 'iPhone XR',
      'iPad8,1': 'iPad Pro 11" (2018)',
      'iPad8,2': 'iPad Pro 11" (2018)',
      'iPad8,3': 'iPad Pro 11" (2018)',
      'iPad8,4': 'iPad Pro 11" (2018)',
      'iPad8,5': 'iPad Pro 12.9" (2018)',
      'iPad8,6': 'iPad Pro 12.9" (2018)',
      'iPad8,7': 'iPad Pro 12.9" (2018)',
      'iPad8,8': 'iPad Pro 12.9" (2018)',
      'iPad8,9': 'iPad Pro 11" (2020)',
      'iPad8,10': 'iPad Pro 11" (2020)',
      'iPad8,11': 'iPad Pro 12.9" (2020)',
      'iPad8,12': 'iPad Pro 12.9" (2020)',
    };
    if (known.containsKey(id)) return known[id]!;
    final iphoneMatch = RegExp(r'^iPhone(\d+),').firstMatch(id);
    if (iphoneMatch != null) {
      final major = int.tryParse(iphoneMatch.group(1)!) ?? 0;
      if (major >= 17) return 'iPhone (旗舰 A18+)';
      if (major >= 15) return 'iPhone (A16/A17)';
      if (major >= 13) return 'iPhone (A14/A15)';
      return 'iPhone ($id)';
    }
    final ipadMatch = RegExp(r'^iPad(\d+),').firstMatch(id);
    if (ipadMatch != null) {
      final major = int.tryParse(ipadMatch.group(1)!) ?? 0;
      if (major >= 16) return 'iPad Pro (M4)';
      if (major >= 14) return 'iPad (M 系列)';
      if (major >= 13) return 'iPad (A14/M1)';
      return 'iPad ($id)';
    }
    return isPad ? 'iPad ($id)' : id;
  }

  static int _appleFamilyMajor(String machineId, String prefix) {
    final m = RegExp('^$prefix(\\d+),').firstMatch(machineId.trim());
    return m != null ? (int.tryParse(m.group(1)!) ?? 0) : 0;
  }

  static DeviceQualityRecommendation recommend(DeviceHardwareSnapshot hw) {
    final gb = hw.memoryGb;
    final iphoneMajor = _appleFamilyMajor(hw.machineIdentifier, 'iPhone');
    final ipadMajor = _appleFamilyMajor(hw.machineIdentifier, 'iPad');
    final isAppleSiliconFlagship =
        iphoneMajor >= 15 || ipadMajor >= 13 || (gb >= 5.5 && hw.processorCount >= 6);
    final isOlderLegacy =
        (iphoneMajor > 0 && iphoneMajor <= 12) ||
        (ipadMajor > 0 && ipadMajor <= 11) ||
        (gb > 0 && gb < 3.6);

    final DeviceHardwareTier tier;
    if (hw.lowPowerMode || hw.thermalState.isThrottled || isOlderLegacy) {
      tier = DeviceHardwareTier.efficiency;
    } else if (isAppleSiliconFlagship && gb >= 5.5) {
      tier = DeviceHardwareTier.flagship;
    } else {
      tier = DeviceHardwareTier.balanced;
    }

    final bool largeBuffer =
        tier == DeviceHardwareTier.flagship && gb >= 5.5 && !hw.lowPowerMode;
    final bool anime4k = tier == DeviceHardwareTier.flagship &&
        !hw.lowPowerMode &&
        !hw.thermalState.isThrottled &&
        (iphoneMajor == 0 || iphoneMajor >= 14) &&
        (ipadMajor == 0 || ipadMajor >= 13);
    final String hdrMode;
    if (hw.potentialEdrHeadroom >= 1.5 || tier == DeviceHardwareTier.flagship) {
      hdrMode = IosHdrToneMappingMode.auto.id;
    } else if (hw.supportsHdrDisplay) {
      hdrMode = IosHdrToneMappingMode.bt2446a.id;
    } else {
      hdrMode = IosHdrToneMappingMode.hable.id;
    }
    final String preferredQuality = tier == DeviceHardwareTier.efficiency
        ? '1080p_direct'
        : '4k_netdisk';
    final int diskCacheMb = switch (tier) {
      DeviceHardwareTier.flagship => 512,
      DeviceHardwareTier.balanced => 256,
      DeviceHardwareTier.efficiency => 128,
    };

    return DeviceQualityRecommendation(
      hardware: hw,
      tier: tier,
      iosPlaybackEngineMode: IosPlaybackEngineMode.avPlayer.id,
      iosHdrToneMappingMode: hdrMode,
      iosAnime4kLightweightEnabled: anime4k,
      iosLargeBufferEnabled: largeBuffer,
      preferredQuality: preferredQuality,
      defaultAspectMode: 'contain',
      playerKernel: 'exo',
      mediaDiskCacheLimitMb: diskCacheMb,
    );
  }

  static Future<DeviceQualityRecommendation> detectAndApply(
    StorageService storage, {
    bool force = false,
    MethodChannel? channelOverride,
  }) async {
    final hw = await detect(channelOverride: channelOverride);
    final rec = recommend(hw);
    if (force || storage.autoHardwareQualityEnabled) {
      await storage.setIosPlaybackEngineMode(rec.iosPlaybackEngineMode);
      await storage.setIosHdrToneMappingMode(rec.iosHdrToneMappingMode);
      await storage.setIosAnime4kLightweightEnabled(
        rec.iosAnime4kLightweightEnabled,
      );
      await storage.setIosLargeBufferEnabled(rec.iosLargeBufferEnabled);
      await storage.setPreferredQuality(rec.preferredQuality);
      await storage.setPlayerKernel(rec.playerKernel);
      await storage.setMediaDiskCacheLimitMb(rec.mediaDiskCacheLimitMb);
      await storage.setLastHardwareProfileSummary(
        '${rec.hardwareSummaryZh} · ${rec.tier.labelZh}',
      );
    }
    return rec;
  }
}

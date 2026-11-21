import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/cast_service.dart';
import '../apple_theme.dart';
import '../ios_glass_popover.dart';

/// Opens the 爱优腾-style TV Casting popover anchored to the top-right Cast
/// button. Shows live LAN DLNA discovery + native iOS AirPlay route picker.
Future<void> showIosCastPopover({
  required BuildContext context,
  required Rect? anchorRect,
  required CastController controller,
  required Future<void> Function(CastDevice device) onSelectDevice,
}) {
  if (!controller.scanning) {
    controller.scanDevices();
  }
  return showIosGlassPopover<void>(
    context: context,
    anchorRect: anchorRect,
    title: '选择投屏设备',
    maxWidth: 310,
    maxHeight: 340,
    forceDark: true,
    trailing: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          minimumSize: const Size(28, 28),
          onPressed: controller.scanning ? null : () => controller.scanDevices(),
          child: controller.scanning
              ? const CupertinoActivityIndicator(
                  radius: 7,
                  color: Colors.white70,
                )
              : const Icon(
                  CupertinoIcons.refresh,
                  size: 15,
                  color: Colors.white70,
                ),
        );
      },
    ),
    builder: (popoverContext) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final devices = controller.devices;
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Native AirPlay row (Apple TV / AirPlay 2 TVs / Mac)
                _CastRowTile(
                  key: const Key('ios-cast-airplay-row'),
                  icon: CupertinoIcons.tv_circle_fill,
                  accent: AppleColors.systemBlue,
                  title: '隔空播放 (AirPlay)',
                  subtitle: 'Apple TV · 支持隔空播放的智能电视',
                  trailing: const Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: Colors.white54,
                  ),
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    Navigator.of(popoverContext).pop();
                    await controller.openAirPlayPicker();
                  },
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      const Text(
                        '局域网 DLNA 电视 / 盒子',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        controller.scanning
                            ? '正在搜索…'
                            : '发现 ${devices.length} 台',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                if (devices.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          controller.scanning
                              ? CupertinoIcons.wifi
                              : CupertinoIcons.tv,
                          size: 24,
                          color: Colors.white54,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          controller.scanning
                              ? '正在搜索同一 Wi-Fi 下的投屏设备…'
                              : (controller.statusMessage ??
                                  '暂未发现 DLNA 电视或盒子'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '请确认手机与电视连接同一 Wi-Fi，并在电视端打开投屏 / 乐播 / DLNA 服务',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 10.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final device in devices) ...[
                    _CastRowTile(
                      key: Key('ios-cast-device-${device.id}'),
                      icon: CupertinoIcons.tv_fill,
                      accent: controller.activeDevice?.id == device.id
                          ? AppleColors.systemGreen
                          : Colors.white,
                      title: device.name,
                      subtitle: device.subtitle,
                      selected: controller.activeDevice?.id == device.id,
                      trailing: controller.activeDevice?.id == device.id
                          ? const Icon(
                              CupertinoIcons.checkmark_circle_fill,
                              size: 16,
                              color: AppleColors.systemGreen,
                            )
                          : const Text(
                              '投屏',
                              style: TextStyle(
                                color: AppleColors.systemBlue,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.of(popoverContext).pop();
                        onSelectDevice(device);
                      },
                    ),
                    const SizedBox(height: 6),
                  ],
              ],
            ),
          );
        },
      );
    },
  );
}

class _CastRowTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool selected;
  final VoidCallback onTap;

  const _CastRowTile({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppleColors.systemBlue.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: selected
                ? AppleColors.systemBlue.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.1),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 17, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1.5),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// 爱优腾-style active casting remote stage rendered inside the player viewport
/// while a TV/DLNA device is playing. Lets the user switch device, exit cast,
/// scrub progress, pause/play, adjust TV volume, and pick episodes/lines.
class IosCastingRemoteStage extends StatelessWidget {
  final CastController controller;
  final String episodeLabel;
  final VoidCallback onBack;
  final VoidCallback onSwitchDevice;
  final VoidCallback onExitCast;
  final VoidCallback? onOpenEpisodes;
  final VoidCallback? onOpenLines;
  final bool compact;

  const IosCastingRemoteStage({
    super.key,
    required this.controller,
    required this.episodeLabel,
    required this.onBack,
    required this.onSwitchDevice,
    required this.onExitCast,
    this.onOpenEpisodes,
    this.onOpenLines,
    this.compact = false,
  });

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final device = controller.activeDevice;
        final isPlaying = controller.state == CastSessionState.playing;
        final isConnecting = controller.state == CastSessionState.connecting;
        final durMs = controller.duration.inMilliseconds.clamp(1, 1 << 31);
        final posMs = controller.position.inMilliseconds.clamp(0, durMs);
        final progress = (posMs / durMs).clamp(0.0, 1.0);

        return Container(
          key: const Key('ios-casting-remote-stage'),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF0E1320),
                Color(0xFF0A0D14),
                Color(0xFF06070A),
              ],
            ),
          ),
          child: SafeArea(
            bottom: !compact,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 14 : 24,
                vertical: compact ? 8 : 14,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top bar: back + casting status + switch device / exit
                  Row(
                    children: [
                      GestureDetector(
                        onTap: onBack,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            CupertinoIcons.chevron_back,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  CupertinoIcons.tv_fill,
                                  size: 13,
                                  color: isConnecting
                                      ? AppleColors.systemOrange
                                      : AppleColors.systemGreen,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    isConnecting
                                        ? '正在连接 ${device?.name ?? "电视"}…'
                                        : '正在投屏到 ${device?.name ?? "电视"}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (episodeLabel.isNotEmpty)
                              Text(
                                episodeLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      _CastPillButton(
                        key: const Key('ios-cast-switch-device'),
                        label: '换设备',
                        onTap: onSwitchDevice,
                      ),
                      const SizedBox(width: 6),
                      _CastPillButton(
                        key: const Key('ios-cast-exit-button'),
                        label: '退出投屏',
                        danger: true,
                        onTap: onExitCast,
                      ),
                    ],
                  ),

                  // Center remote controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RemoteCircleBtn(
                        icon: CupertinoIcons.speaker_1_fill,
                        label: '音量-',
                        onTap: () => controller.adjustVolume(-8),
                      ),
                      const SizedBox(width: 14),
                      _RemoteCircleBtn(
                        icon: CupertinoIcons.gobackward_15,
                        label: '-15s',
                        onTap: () => controller.seek(
                          controller.position - const Duration(seconds: 15),
                        ),
                      ),
                      const SizedBox(width: 18),
                      GestureDetector(
                        key: const Key('ios-cast-play-pause'),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          controller.togglePlayPause();
                        },
                        child: Container(
                          width: compact ? 52 : 62,
                          height: compact ? 52 : 62,
                          decoration: BoxDecoration(
                            color: AppleColors.systemBlue.withValues(alpha: 0.92),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppleColors.systemBlue.withValues(alpha: 0.35),
                                blurRadius: 18,
                              ),
                            ],
                          ),
                          child: Icon(
                            isPlaying
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            color: Colors.white,
                            size: compact ? 24 : 28,
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      _RemoteCircleBtn(
                        icon: CupertinoIcons.goforward_15,
                        label: '+15s',
                        onTap: () => controller.seek(
                          controller.position + const Duration(seconds: 15),
                        ),
                      ),
                      const SizedBox(width: 14),
                      _RemoteCircleBtn(
                        icon: CupertinoIcons.speaker_3_fill,
                        label: '音量+',
                        onTap: () => controller.adjustVolume(8),
                      ),
                    ],
                  ),

                  // Bottom progress scrubber + quick episode/line chips
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            _fmt(controller.position),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3.5,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 14,
                                ),
                                activeTrackColor: AppleColors.systemBlue,
                                inactiveTrackColor:
                                    Colors.white.withValues(alpha: 0.2),
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: progress,
                                onChanged: (v) {
                                  if (controller.duration > Duration.zero) {
                                    controller.seek(
                                      Duration(
                                        milliseconds:
                                            (controller.duration.inMilliseconds * v)
                                                .round(),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          ),
                          Text(
                            _fmt(controller.duration),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      if (!compact && (onOpenEpisodes != null || onOpenLines != null))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (onOpenEpisodes != null)
                                _CastPillButton(
                                  label: '选集',
                                  onTap: onOpenEpisodes!,
                                ),
                              if (onOpenEpisodes != null && onOpenLines != null)
                                const SizedBox(width: 10),
                              if (onOpenLines != null)
                                _CastPillButton(
                                  label: '切换线路',
                                  onTap: onOpenLines!,
                                ),
                              const SizedBox(width: 10),
                              Text(
                                '电视音量 ${controller.volume}%',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CastPillButton extends StatelessWidget {
  final String label;
  final bool danger;
  final VoidCallback onTap;

  const _CastPillButton({
    super.key,
    required this.label,
    this.danger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: danger
              ? AppleColors.systemRed.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: danger
                ? AppleColors.systemRed.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.18),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: danger ? const Color(0xFFFF8E88) : Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _RemoteCircleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RemoteCircleBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.11),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.14),
                width: 0.8,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

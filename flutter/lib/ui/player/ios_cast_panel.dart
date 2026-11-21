import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/cast_service.dart';
import '../apple_theme.dart';
import '../ios_glass_popover.dart';
import '../poster_image.dart';

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
    maxWidth: 316,
    maxHeight: 380,
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
                          '请确认手机与电视在同一 Wi-Fi（关闭代理/VPN），并已允许「本地网络」权限',
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
                const SizedBox(height: 4),
                _CastRowTile(
                  key: const Key('ios-cast-manual-ip-row'),
                  icon: CupertinoIcons.add_circled_solid,
                  accent: AppleColors.systemTeal,
                  title: '手动输入电视 IP 连接',
                  subtitle: '免组播直连 Marco Movie TV 或任意 DLNA 电视',
                  trailing: const Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: Colors.white54,
                  ),
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    final input = await _promptManualTvAddress(popoverContext);
                    if (input == null || input.trim().isEmpty) return;
                    final dev = await controller.probeManualTarget(input);
                    if (dev != null && popoverContext.mounted) {
                      Navigator.of(popoverContext).pop();
                      await onSelectDevice(dev);
                    }
                  },
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<String?> _promptManualTvAddress(BuildContext context) async {
  final textCtrl = TextEditingController();
  try {
    return await showCupertinoDialog<String>(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: const Text('手动连接局域网电视'),
        content: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '输入电视局域网 IP（如 10.0.0.88 或电视端显示的 IP:端口）',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              CupertinoTextField(
                key: const Key('ios-cast-manual-ip-field'),
                controller: textCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                placeholder: '电视局域网 IP 或 IP:18652',
                clearButtonMode: OverlayVisibilityMode.editing,
                onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogCtx).pop(textCtrl.text.trim()),
            child: const Text('探测并投屏'),
          ),
        ],
      ),
    );
  } finally {
    textCtrl.dispose();
  }
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

/// 爱优腾 / Apple TV Remote-style active casting remote control stage.
///
/// In iOS portrait mode (`halfScreen: true`), the player viewport smoothly
/// expands to ~half screen height and transforms into a full-featured TV
/// remote with play/pause, ±15s seek, smooth progress scrub, previous/next
/// episode switching, playback speed pills, TV volume/mute rocker, and quick
/// episode/line sheets.
class IosCastingRemoteStage extends StatefulWidget {
  final CastController controller;
  final String episodeLabel;
  final String? posterUrl;
  final VoidCallback onBack;
  final VoidCallback onSwitchDevice;
  final VoidCallback onExitCast;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onOpenEpisodes;
  final VoidCallback? onOpenLines;
  final bool compact;
  final bool halfScreen;

  const IosCastingRemoteStage({
    super.key,
    required this.controller,
    required this.episodeLabel,
    this.posterUrl,
    required this.onBack,
    required this.onSwitchDevice,
    required this.onExitCast,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.onOpenEpisodes,
    this.onOpenLines,
    this.compact = false,
    this.halfScreen = false,
  });

  @override
  State<IosCastingRemoteStage> createState() => _IosCastingRemoteStageState();
}

class _IosCastingRemoteStageState extends State<IosCastingRemoteStage> {
  static const List<double> _speedOptions = [0.75, 1.0, 1.25, 1.5, 2.0];

  double? _draggingProgress;

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

  String _formatSpeedLabel(double speed) {
    if ((speed - speed.roundToDouble()).abs() < 0.001) {
      return '${speed.toStringAsFixed(1)}x';
    }
    return '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')}x';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final device = controller.activeDevice;
        final isPlaying = controller.state == CastSessionState.playing;
        final isConnecting = controller.state == CastSessionState.connecting;
        final durMs = controller.duration.inMilliseconds.clamp(1, 1 << 31);
        final posMs = controller.position.inMilliseconds.clamp(0, durMs);
        final liveProgress = (posMs / durMs).clamp(0.0, 1.0);
        final sliderProgress = (_draggingProgress ?? liveProgress).clamp(0.0, 1.0);
        final displayPos = _draggingProgress != null && controller.duration > Duration.zero
            ? Duration(
                milliseconds: (controller.duration.inMilliseconds * sliderProgress).round(),
              )
            : controller.position;

        final poster = widget.posterUrl?.trim() ?? '';

        return LayoutBuilder(
          builder: (context, constraints) {
            final availH = constraints.maxHeight;
            final expandedRemote = widget.halfScreen || (!widget.compact && availH >= 320);
            final tight = availH < 345;
            final centerSize = expandedRemote ? (tight ? 58.0 : 66.0) : (widget.compact ? 50.0 : 60.0);
            final sideBtnSize = expandedRemote ? (tight ? 42.0 : 46.0) : 40.0;

            return ClipRect(
              child: Container(
                key: const Key('ios-casting-remote-stage'),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF131B2E),
                      Color(0xFF0C101B),
                      Color(0xFF070A11),
                    ],
                  ),
                  border: widget.halfScreen
                      ? Border(
                          bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 0.7,
                          ),
                        )
                      : null,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (poster.isNotEmpty)
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.22,
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                            child: PosterImage(
                              url: poster,
                              fit: BoxFit.cover,
                              placeholder: const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              const Color(0xFF0E1424).withValues(alpha: 0.72),
                              const Color(0xFF0A0E18).withValues(alpha: 0.86),
                              const Color(0xFF070910).withValues(alpha: 0.96),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      top: !widget.halfScreen,
                      bottom: !widget.compact && !widget.halfScreen,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: expandedRemote ? 18 : (widget.compact ? 14 : 24),
                          vertical: expandedRemote ? (tight ? 10 : 14) : (widget.compact ? 8 : 14),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // 1. Top header: Back + Casting Status + Switch Device / Exit
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: widget.onBack,
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.12),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.14),
                                        width: 0.7,
                                      ),
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
                                          Container(
                                            width: 7,
                                            height: 7,
                                            decoration: BoxDecoration(
                                              color: isConnecting
                                                  ? AppleColors.systemOrange
                                                  : AppleColors.systemGreen,
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: (isConnecting
                                                          ? AppleColors.systemOrange
                                                          : AppleColors.systemGreen)
                                                      .withValues(alpha: 0.6),
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              isConnecting
                                                  ? '正在连接 ${device?.name ?? "电视"}…'
                                                  : '正在投屏 · ${device?.name ?? "电视"}',
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
                                      if (widget.episodeLabel.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 1.5),
                                          child: Text(
                                            widget.episodeLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _CastPillButton(
                                  key: const Key('ios-cast-switch-device'),
                                  label: '换设备',
                                  onTap: widget.onSwitchDevice,
                                ),
                                const SizedBox(width: 6),
                                _CastPillButton(
                                  key: const Key('ios-cast-exit-button'),
                                  label: '退出投屏',
                                  danger: true,
                                  onTap: widget.onExitCast,
                                ),
                              ],
                            ),

                            // 2. Main Remote Transport Deck (Prev Episode / -15s / Play-Pause / +15s / Next Episode)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: expandedRemote ? (tight ? 2 : 6) : 0,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (expandedRemote)
                                    _RemoteCircleBtn(
                                      key: const Key('ios-cast-prev-episode'),
                                      icon: CupertinoIcons.backward_end_fill,
                                      label: '上一集',
                                      size: sideBtnSize,
                                      enabled: widget.onPreviousEpisode != null,
                                      onTap: widget.onPreviousEpisode ?? () {},
                                    )
                                  else
                                    _RemoteCircleBtn(
                                      icon: CupertinoIcons.speaker_1_fill,
                                      label: '音量-',
                                      size: sideBtnSize,
                                      onTap: () => controller.adjustVolume(-8),
                                    ),
                                  _RemoteCircleBtn(
                                    key: const Key('ios-cast-seek-back'),
                                    icon: CupertinoIcons.gobackward_15,
                                    label: '快退15s',
                                    size: sideBtnSize,
                                    onTap: () => controller.seek(
                                      controller.position - const Duration(seconds: 15),
                                    ),
                                  ),
                                  GestureDetector(
                                    key: const Key('ios-cast-play-pause'),
                                    onTap: () {
                                      HapticFeedback.mediumImpact();
                                      controller.togglePlayPause();
                                    },
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: centerSize,
                                          height: centerSize,
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                AppleColors.systemBlue,
                                                AppleColors.systemBlue.withValues(alpha: 0.78),
                                              ],
                                            ),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white.withValues(alpha: 0.28),
                                              width: 1.0,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: AppleColors.systemBlue
                                                    .withValues(alpha: 0.42),
                                                blurRadius: 20,
                                                spreadRadius: 1,
                                              ),
                                            ],
                                          ),
                                          child: Icon(
                                            isPlaying
                                                ? CupertinoIcons.pause_fill
                                                : CupertinoIcons.play_fill,
                                            color: Colors.white,
                                            size: expandedRemote ? 30 : 24,
                                          ),
                                        ),
                                        if (expandedRemote) ...[
                                          const SizedBox(height: 5),
                                          Text(
                                            isPlaying ? '暂停' : '播放',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  _RemoteCircleBtn(
                                    key: const Key('ios-cast-seek-forward'),
                                    icon: CupertinoIcons.goforward_15,
                                    label: '快进15s',
                                    size: sideBtnSize,
                                    onTap: () => controller.seek(
                                      controller.position + const Duration(seconds: 15),
                                    ),
                                  ),
                                  if (expandedRemote)
                                    _RemoteCircleBtn(
                                      key: const Key('ios-cast-next-episode'),
                                      icon: CupertinoIcons.forward_end_fill,
                                      label: '下一集',
                                      size: sideBtnSize,
                                      enabled: widget.onNextEpisode != null,
                                      onTap: widget.onNextEpisode ?? () {},
                                    )
                                  else
                                    _RemoteCircleBtn(
                                      icon: CupertinoIcons.speaker_3_fill,
                                      label: '音量+',
                                      size: sideBtnSize,
                                      onTap: () => controller.adjustVolume(8),
                                    ),
                                ],
                              ),
                            ),

                            // 3. Smooth Scrubber Progress Bar
                            Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    _fmt(displayPos),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: expandedRemote ? 4.5 : 3.5,
                                      thumbShape: RoundSliderThumbShape(
                                        enabledThumbRadius: expandedRemote ? 7.5 : 6,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 15,
                                      ),
                                      activeTrackColor: AppleColors.systemBlue,
                                      inactiveTrackColor:
                                          Colors.white.withValues(alpha: 0.2),
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      key: const Key('ios-cast-progress-slider'),
                                      value: sliderProgress,
                                      onChangeStart: (v) {
                                        setState(() => _draggingProgress = v);
                                      },
                                      onChanged: (v) {
                                        setState(() => _draggingProgress = v);
                                      },
                                      onChangeEnd: (v) {
                                        setState(() => _draggingProgress = null);
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
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    _fmt(controller.duration),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11.5,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            // 4. Playback Speed Strip (`0.75x / 1.0x / 1.25x / 1.5x / 2.0x`)
                            if (expandedRemote)
                              Container(
                                key: const Key('ios-cast-speed-strip'),
                                padding: const EdgeInsets.all(3.5),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.11),
                                    width: 0.7,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 9),
                                      child: Text(
                                        '倍速',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    for (final s in _speedOptions)
                                      Expanded(
                                        child: GestureDetector(
                                          key: Key(
                                            'ios-cast-speed-${_formatSpeedLabel(s)}',
                                          ),
                                          onTap: () {
                                            HapticFeedback.selectionClick();
                                            controller.setSpeed(s);
                                          },
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 180),
                                            padding: const EdgeInsets.symmetric(vertical: 6.5),
                                            decoration: BoxDecoration(
                                              color: (controller.speed - s).abs() < 0.01
                                                  ? AppleColors.systemBlue
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              _formatSpeedLabel(s),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: (controller.speed - s).abs() < 0.01
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontSize: 11.5,
                                                fontWeight: (controller.speed - s).abs() < 0.01
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                            // 5. Bottom Remote Utility Bar: TV Volume Rocker + Quick Episodes / Lines
                            if (expandedRemote)
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      key: const Key('ios-cast-volume-capsule'),
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.09),
                                        borderRadius: BorderRadius.circular(13),
                                        border: Border.all(
                                          color: Colors.white.withValues(alpha: 0.12),
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: GestureDetector(
                                              key: const Key('ios-cast-vol-down'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.adjustVolume(-8);
                                              },
                                              child: const Center(
                                                child: Icon(
                                                  CupertinoIcons.speaker_1_fill,
                                                  color: Colors.white70,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 0.6,
                                            height: 18,
                                            color: Colors.white.withValues(alpha: 0.14),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: GestureDetector(
                                              key: const Key('ios-cast-mute-toggle'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.toggleMute();
                                              },
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    controller.muted
                                                        ? CupertinoIcons.speaker_slash_fill
                                                        : CupertinoIcons.speaker_2_fill,
                                                    color: controller.muted
                                                        ? AppleColors.systemOrange
                                                        : Colors.white70,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    controller.muted
                                                        ? '已静音'
                                                        : '${controller.volume}%',
                                                    style: TextStyle(
                                                      color: controller.muted
                                                          ? AppleColors.systemOrange
                                                          : Colors.white70,
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w600,
                                                      fontFeatures: const [
                                                        FontFeature.tabularFigures(),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 0.6,
                                            height: 18,
                                            color: Colors.white.withValues(alpha: 0.14),
                                          ),
                                          Expanded(
                                            child: GestureDetector(
                                              key: const Key('ios-cast-vol-up'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.adjustVolume(8);
                                              },
                                              child: const Center(
                                                child: Icon(
                                                  CupertinoIcons.speaker_3_fill,
                                                  color: Colors.white70,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (widget.onOpenEpisodes != null) ...[
                                    const SizedBox(width: 8),
                                    _RemoteActionChip(
                                      key: const Key('ios-cast-open-episodes'),
                                      icon: CupertinoIcons.square_grid_2x2_fill,
                                      label: '选集',
                                      onTap: widget.onOpenEpisodes!,
                                    ),
                                  ],
                                  if (widget.onOpenLines != null) ...[
                                    const SizedBox(width: 8),
                                    _RemoteActionChip(
                                      key: const Key('ios-cast-open-lines'),
                                      icon: CupertinoIcons.layers_alt_fill,
                                      label: '换线路',
                                      onTap: widget.onOpenLines!,
                                    ),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _RemoteActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RemoteActionChip({
    super.key,
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
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
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
  final double size;
  final bool enabled;
  final VoidCallback onTap;

  const _RemoteCircleBtn({
    super.key,
    required this.icon,
    required this.label,
    this.size = 42,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.34,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.11),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 0.8,
                ),
              ),
              child: Icon(icon, color: Colors.white, size: size * 0.44),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

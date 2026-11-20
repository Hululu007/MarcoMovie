import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../core/media_badges.dart';
import '../core/ohos_runtime.dart';
import 'apple_theme.dart';

class _BadgePalette {
  const _BadgePalette({
    required this.text,
    required this.glassFill,
    required this.solidFill,
    required this.border,
  });

  final Color text;
  final Color glassFill;
  final Color solidFill;
  final Color border;
}

_BadgePalette _paletteForStyle(String style) {
  switch (style) {
    case 'uhdGold':
      return const _BadgePalette(
        text: Color(0xFFFFDF7A),
        glassFill: Color(0x38D97706),
        solidFill: Color(0xE0422A06),
        border: Color(0x78F59E0B),
      );
    case 'hdCyan':
      return const _BadgePalette(
        text: Color(0xFF7DD3FC),
        glassFill: Color(0x340284C7),
        solidFill: Color(0xE00A2E44),
        border: Color(0x6E38BDF8),
      );
    case 'sdNeutral':
      return const _BadgePalette(
        text: Color(0xFFD4D4D8),
        glassFill: Color(0x2E52525B),
        solidFill: Color(0xE027272A),
        border: Color(0x5EA1A1AA),
      );
    case 'visionPurple':
      return const _BadgePalette(
        text: Color(0xFFD8B4FE),
        glassFill: Color(0x3A7E22CE),
        solidFill: Color(0xE031124D),
        border: Color(0x78A855F7),
      );
    case 'hdrBlue':
      return const _BadgePalette(
        text: Color(0xFF93C5FD),
        glassFill: Color(0x361D4ED8),
        solidFill: Color(0xE013254D),
        border: Color(0x7260A5FA),
      );
    case 'discEmerald':
      return const _BadgePalette(
        text: Color(0xFF6EE7B7),
        glassFill: Color(0x34047857),
        solidFill: Color(0xE00A3528),
        border: Color(0x6E34D399),
      );
    case 'streamTeal':
      return const _BadgePalette(
        text: Color(0xFF5EEAD4),
        glassFill: Color(0x320F766E),
        solidFill: Color(0xE00B3330),
        border: Color(0x682DD4BF),
      );
    case 'spatialAudio':
      return const _BadgePalette(
        text: Color(0xFFFDBA74),
        glassFill: Color(0x38C2410C),
        solidFill: Color(0xE0431E0C),
        border: Color(0x74FB923C),
      );
    case 'standardAudio':
      return const _BadgePalette(
        text: Color(0xFFBFDBFE),
        glassFill: Color(0x2E334155),
        solidFill: Color(0xE01E293B),
        border: Color(0x6294A3B8),
      );
    case 'codecSlate':
      return const _BadgePalette(
        text: Color(0xFFE2E8F0),
        glassFill: Color(0x2C334155),
        solidFill: Color(0xE01E293B),
        border: Color(0x5C94A3B8),
      );
    case 'platformTag':
      return const _BadgePalette(
        text: Color(0xFFF0ABFC),
        glassFill: Color(0x2E581C87),
        solidFill: Color(0xE02D1145),
        border: Color(0x62C084FC),
      );
    case 'premiumCombo':
      return const _BadgePalette(
        text: Color(0xFFFEF08A),
        glassFill: Color(0x446D28D9),
        solidFill: Color(0xE6361A66),
        border: Color(0x88FACC15),
      );
    default:
      return const _BadgePalette(
        text: Color(0xFFE5E7EB),
        glassFill: Color(0x2E374151),
        solidFill: Color(0xE01F2937),
        border: Color(0x5C9CA3AF),
      );
  }
}

bool get _isWindowsFastGlass => !kIsWeb && Platform.isWindows;

/// Single plain-text typography media specification capsule pill.
///
/// - iOS / macOS: concentric rounded glass pill (`radius = height/2`) respecting
///   [GlassworkBackdrop.reduceTransparency].
/// - Windows (`winFastGlass`): crisp solid stroke pill with zero blur.
/// - HarmonyOS NEXT (`OhosRuntime.isOhos`): returns [SizedBox.shrink].
class MediaBadgePill extends StatelessWidget {
  const MediaBadgePill(
    this.badge, {
    super.key,
    this.compact = false,
    this.windowsSolid = false,
  });

  final MediaBadge badge;
  final bool compact;
  final bool windowsSolid;

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) {
      return const SizedBox.shrink();
    }
    final palette = _paletteForStyle(badge.style);
    final highContrast = MediaQuery.highContrastOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: GlassworkBackdrop.reduceTransparency,
      builder: (context, reduceTransparency, _) {
        final useSolid =
            windowsSolid || _isWindowsFastGlass || reduceTransparency || highContrast;
        final bgColor = useSolid ? palette.solidFill : palette.glassFill;
        final borderColor =
            highContrast ? palette.text.withValues(alpha: 0.9) : palette.border;
        return Container(
          key: ValueKey('media-badge-${badge.id}'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 9,
            vertical: compact ? 2 : 3,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: borderColor,
              width: useSolid ? 0.9 : 0.75,
            ),
          ),
          child: Text(
            badge.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(
              color: palette.text,
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.25,
              height: 1.15,
            ),
          ),
        );
      },
    );
  }
}

/// Wrapping row of plain-text media specification pills.
class MediaBadgeRow extends StatelessWidget {
  const MediaBadgeRow({
    super.key,
    required this.badges,
    this.maxBadges = 5,
    this.compact = false,
    this.windowsSolid = false,
    this.alignment = WrapAlignment.start,
  });

  final List<MediaBadge> badges;
  final int maxBadges;
  final bool compact;
  final bool windowsSolid;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos || badges.isEmpty || maxBadges == 0) {
      return const SizedBox.shrink();
    }
    final visible = maxBadges > 0 && badges.length > maxBadges
        ? badges.take(maxBadges)
        : badges;
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: compact ? 5 : 7,
      runSpacing: compact ? 4 : 6,
      children: [
        for (final badge in visible)
          MediaBadgePill(
            badge,
            compact: compact,
            windowsSolid: windowsSolid,
          ),
      ],
    );
  }
}

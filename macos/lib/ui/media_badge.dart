// SPDX-License-Identifier: GPL-3.0-only
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

/// Palette locked 1:1 with `shared/ui-spec/motion-tokens.json#badgeStyles`.
_BadgePalette _paletteForStyle(String style) {
  switch (style) {
    case 'uhdGold':
      return const _BadgePalette(
        text: Color(0xFFFFB340),
        glassFill: Color(0x2EFF9F0A),
        solidFill: Color(0xEB3A2810),
        border: Color(0x66FF9F0A),
      );
    case 'hdCyan':
      return const _BadgePalette(
        text: Color(0xFF70D7FF),
        glassFill: Color(0x2964D2FF),
        solidFill: Color(0xEB142C38),
        border: Color(0x5C64D2FF),
      );
    case 'sdNeutral':
      return const _BadgePalette(
        text: Color(0xFFD1D1DA),
        glassFill: Color(0x33787884),
        solidFill: Color(0xEB25252B),
        border: Color(0x4DEBEBF5),
      );
    case 'premiumCombo':
      return const _BadgePalette(
        text: Color(0xFFE5C7FF),
        glassFill: Color(0x335E5CE6),
        solidFill: Color(0xEB261F42),
        border: Color(0x73BF5AF2),
      );
    case 'visionPurple':
      return const _BadgePalette(
        text: Color(0xFFDEB0FF),
        glassFill: Color(0x2EBF5AF2),
        solidFill: Color(0xEB2D1B38),
        border: Color(0x66BF5AF2),
      );
    case 'hdrBlue':
      return const _BadgePalette(
        text: Color(0xFF64D2FF),
        glassFill: Color(0x2E0A84FF),
        solidFill: Color(0xEB122640),
        border: Color(0x660A84FF),
      );
    case 'discEmerald':
      return const _BadgePalette(
        text: Color(0xFF63E682),
        glassFill: Color(0x2930D158),
        solidFill: Color(0xEB142E1C),
        border: Color(0x5C30D158),
      );
    case 'streamTeal':
      return const _BadgePalette(
        text: Color(0xFF82D7FF),
        glassFill: Color(0x265AC8FA),
        solidFill: Color(0xEB152936),
        border: Color(0x525AC8FA),
      );
    case 'spatialAudio':
      return const _BadgePalette(
        text: Color(0xFF8AE0FF),
        glassFill: Color(0x2E0A84FF),
        solidFill: Color(0xEB13283D),
        border: Color(0x665AC8FA),
      );
    case 'standardAudio':
      return const _BadgePalette(
        text: Color(0xFFF5F5F7),
        glassFill: Color(0x38787884),
        solidFill: Color(0xEB28282E),
        border: Color(0x3BFFFFFF),
      );
    case 'codecSlate':
      return const _BadgePalette(
        text: Color(0xFFD1D1DA),
        glassFill: Color(0x29787884),
        solidFill: Color(0xEB222228),
        border: Color(0x29FFFFFF),
      );
    case 'platformTag':
      return const _BadgePalette(
        text: Color(0xFFEBEBF5),
        glassFill: Color(0x2E36363D),
        solidFill: Color(0xEB28282E),
        border: Color(0x45FFFFFF),
      );
    default:
      return const _BadgePalette(
        text: Color(0xFFD1D1DA),
        glassFill: Color(0x29787884),
        solidFill: Color(0xEB222228),
        border: Color(0x3BFFFFFF),
      );
  }
}

Color _ensureMinAlpha(Color color, double minAlpha) {
  return color.a >= minAlpha ? color : color.withValues(alpha: minAlpha);
}

final Listenable _badgeSurfaceListenable = Listenable.merge(<Listenable>[
  GlassworkBackdrop.reduceTransparency,
  GlassworkBackdrop.intensity,
]);

/// Single plain-text typography media specification capsule pill.
///
/// - iOS / macOS: concentric rounded glass pill (`radius = height/2`, `999`)
///   respecting [GlassworkBackdrop.reduceTransparency],
///   [GlassworkBackdrop.intensity] (`glassBlurLevel == 'solid'`), and high
///   contrast.
/// - Windows (`winFastGlass` / [isWindowsDesktopUi]): crisp solid stroke pill
///   with `5`/`6` corner radius and zero blur.
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
    final isWin = windowsSolid || isWindowsDesktopUi;
    final radius = isWin ? (compact ? 5.0 : 6.0) : 999.0;
    return ListenableBuilder(
      listenable: _badgeSurfaceListenable,
      builder: (context, _) {
        final solidMode = isWin ||
            GlassworkBackdrop.reduceTransparency.value ||
            GlassworkBackdrop.intensity.value <= 0.02 ||
            highContrast;
        final bgColor = solidMode ? palette.solidFill : palette.glassFill;
        final borderColor = highContrast
            ? palette.text.withValues(alpha: 0.9)
            : (solidMode ? _ensureMinAlpha(palette.border, 0.45) : palette.border);
        return Container(
          key: ValueKey('media-badge-${badge.id}'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 8,
            vertical: compact ? 2 : 3,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: borderColor,
              width: 1.0,
            ),
          ),
          child: Text(
            badge.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: TextStyle(
              color: palette.text,
              fontSize: compact ? 11 : 12,
              fontWeight: compact ? FontWeight.w600 : FontWeight.w700,
              letterSpacing: compact ? 0.3 : 0.35,
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
      spacing: compact ? 4 : 6,
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

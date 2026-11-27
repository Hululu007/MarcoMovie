// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared Apple TV-parity living-room visual tokens for HarmonyOS Smart Screen.
abstract final class TvAmbientColors {
  static const Color background = Color(0xFF0F1A29);
  static const Color surface = Color(0x18FFFFFF); // white 0.095
  static const Color elevatedSurface = Color(0x23FFFFFF); // white 0.135
  static const Color glassFill = Color(0x21FFFFFF); // white 0.13
  static const Color glassStroke = Color(0x3DFFFFFF); // white 0.24
  static const Color accent = Color(0xFF388FFA); // (0.22, 0.56, 0.98)
  static const Color gold = Color(0xFFF5C247); // (0.96, 0.76, 0.28)
  static const Color secondaryText = Color(0xCCFFFFFF); // white 0.80
  static const Color mutedText = Color(0x94FFFFFF); // white 0.58
  static const Color darkInk = Color(0xFF0A0F1A);
}

/// 1:1 color-matched living-room ambient soft-glow preset (shared with Apple TV).
class TvAmbientPreset {
  final String id;
  final String name;
  final String subtitle;
  final Color baseStart;
  final Color baseMid;
  final Color baseEnd;
  final Color orbPrimary;
  final Color orbSecondary;
  final Color orbWarm;
  final Color accent;

  const TvAmbientPreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.baseStart,
    required this.baseMid,
    required this.baseEnd,
    required this.orbPrimary,
    required this.orbSecondary,
    required this.orbWarm,
    required this.accent,
  });

  static const List<TvAmbientPreset> allPresets = <TvAmbientPreset>[
    TvAmbientPreset(
      id: 'aurora',
      name: '极光青翠',
      subtitle: '翡翠湖光与晴空柔雾',
      baseStart: Color(0xFF0F2B3D),
      baseMid: Color(0xFF121F38),
      baseEnd: Color(0xFF1A1A3B),
      orbPrimary: Color(0xFF14C7AD),
      orbSecondary: Color(0xFF3894FA),
      orbWarm: Color(0xFF6157E0),
      accent: Color(0xFF2E94F5),
    ),
    TvAmbientPreset(
      id: 'twilight',
      name: '暮色流光',
      subtitle: '鸢尾紫霞与玫瑰晚风',
      baseStart: Color(0xFF291C47),
      baseMid: Color(0xFF1C1A38),
      baseEnd: Color(0xFF2E1A33),
      orbPrimary: Color(0xFF8561FA),
      orbSecondary: Color(0xFFEB529E),
      orbWarm: Color(0xFFF08057),
      accent: Color(0xFF7570FA),
    ),
    TvAmbientPreset(
      id: 'ocean',
      name: '深海晨雾',
      subtitle: '冰川海湾与蔚蓝天际',
      baseStart: Color(0xFF0F2947),
      baseMid: Color(0xFF0F1C36),
      baseEnd: Color(0xFF0D2436),
      orbPrimary: Color(0xFF24A3FA),
      orbSecondary: Color(0xFF14C7E0),
      orbWarm: Color(0xFF4266D6),
      accent: Color(0xFF3394FA),
    ),
    TvAmbientPreset(
      id: 'amber',
      name: '暖金影院',
      subtitle: '胡桃木暖灯与胶片琥珀',
      baseStart: Color(0xFF36211A),
      baseMid: Color(0xFF211A21),
      baseEnd: Color(0xFF2B1721),
      orbPrimary: Color(0xFFEB8F2E),
      orbSecondary: Color(0xFFD14761),
      orbWarm: Color(0xFF9E6B38),
      accent: Color(0xFFE69438),
    ),
    TvAmbientPreset(
      id: 'nebula',
      name: '星云紫夜',
      subtitle: '深空星尘与极夜紫罗兰',
      baseStart: Color(0xFF291745),
      baseMid: Color(0xFF171430),
      baseEnd: Color(0xFF12243D),
      orbPrimary: Color(0xFFA34DF5),
      orbSecondary: Color(0xFF299EE6),
      orbWarm: Color(0xFFD642A8),
      accent: Color(0xFF8F66FA),
    ),
    TvAmbientPreset(
      id: 'frost',
      name: '冰川银雾',
      subtitle: '通透银灰与克制微光',
      baseStart: Color(0xFF1C2636),
      baseMid: Color(0xFF141A26),
      baseEnd: Color(0xFF1A2130),
      orbPrimary: Color(0xFF7099C7),
      orbSecondary: Color(0xFF478FC7),
      orbWarm: Color(0xFF5C7094),
      accent: Color(0xFF4294F5),
    ),
  ];

  static TvAmbientPreset forId(String id) {
    final lower = id.trim().toLowerCase();
    for (final p in allPresets) {
      if (p.id == lower) return p;
    }
    return allPresets.first;
  }
}

/// 60fps GPU-friendly multi-layered soft-glow ambient backdrop for HarmonyOS Smart Screen.
/// Replicates Apple TV's `TvAmbientSoftGlowBackground` with smooth orb lighting and
/// optional dynamic focused-poster ambient tinting (zero heavy full-screen blur jank).
class TvAmbientSoftGlowBackground extends StatelessWidget {
  final String themeId;
  final String intensity;
  final Color? posterAmbientColor;
  final bool posterSync;

  const TvAmbientSoftGlowBackground({
    super.key,
    this.themeId = 'aurora',
    this.intensity = 'standard',
    this.posterAmbientColor,
    this.posterSync = true,
  });

  double get _gain => switch (intensity) {
    'soft' => 0.72,
    'vivid' => 1.32,
    _ => 1.0,
  };

  @override
  Widget build(BuildContext context) {
    final preset = TvAmbientPreset.forId(themeId);
    final gain = _gain;
    final tint = posterSync ? posterAmbientColor : null;

    return RepaintBoundary(
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(
          begin: tint ?? Colors.transparent,
          end: tint ?? Colors.transparent,
        ),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, animatedTint, _) {
          return CustomPaint(
            painter: _TvAmbientGlowPainter(
              preset: preset,
              gain: gain,
              posterTint: animatedTint,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _TvAmbientGlowPainter extends CustomPainter {
  final TvAmbientPreset preset;
  final double gain;
  final Color? posterTint;

  const _TvAmbientGlowPainter({
    required this.preset,
    required this.gain,
    required this.posterTint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;

    // 1. Diagonal base gradient
    final basePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [preset.baseStart, preset.baseMid, preset.baseEnd],
      ).createShader(rect);
    canvas.drawRect(rect, basePaint);

    void drawOrb(
      Color color,
      double alpha,
      double cx,
      double cy,
      double radiusFactor,
    ) {
      final center = Offset(w * cx, h * cy);
      final radius = (w * radiusFactor).clamp(160.0, 2400.0);
      final clampedAlpha = (alpha * gain).clamp(0.0, 0.85);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: clampedAlpha),
            color.withValues(alpha: clampedAlpha * 0.42),
            Colors.transparent,
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, paint);
    }

    // 2. Four positioned soft-glow orbs matching Apple TV TvAmbientSoftGlowBackground
    drawOrb(preset.orbPrimary, 0.46, 0.14, 0.18, 0.64);
    drawOrb(preset.orbSecondary, 0.42, 0.86, 0.22, 0.60);
    drawOrb(preset.orbSecondary, 0.24, 0.50, 0.06, 0.44);
    drawOrb(preset.orbWarm, 0.36, 0.52, 0.94, 0.66);

    // 3. Optional subtle poster-color sync glaze
    if (posterTint != null && posterTint!.a > 0.01) {
      drawOrb(posterTint!, 0.22, 0.50, 0.42, 0.68);
    }
  }

  @override
  bool shouldRepaint(covariant _TvAmbientGlowPainter oldDelegate) {
    return oldDelegate.preset.id != preset.id ||
        oldDelegate.gain != gain ||
        oldDelegate.posterTint != posterTint;
  }
}

/// Visual gradient swatch preview used inside HarmonyOS Smart Screen Settings -> 外观与柔光.
class TvAmbientPresetSwatch extends StatelessWidget {
  final TvAmbientPreset preset;
  final bool selected;

  const TvAmbientPresetSwatch({
    super.key,
    required this.preset,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 78,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _TvSwatchPainter(preset),
              child: const SizedBox.expand(),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: 1,
                ),
              ),
            ),
            if (selected)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.58),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.checkmark_alt_circle_fill,
                        size: 13,
                        color: Colors.white,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '当前主题',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TvSwatchPainter extends CustomPainter {
  final TvAmbientPreset preset;
  const _TvSwatchPainter(this.preset);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [preset.baseStart, preset.baseMid, preset.baseEnd],
        ).createShader(rect),
    );
    void orb(Color c, double a, double cx, double cy, double r) {
      final center = Offset(size.width * cx, size.height * cy);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [c.withValues(alpha: a), Colors.transparent],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }

    orb(preset.orbPrimary, 0.78, 0.22, 0.30, size.width * 0.65);
    orb(preset.orbSecondary, 0.72, 0.82, 0.65, size.width * 0.62);
  }

  @override
  bool shouldRepaint(covariant _TvSwatchPainter oldDelegate) =>
      oldDelegate.preset.id != preset.id;
}

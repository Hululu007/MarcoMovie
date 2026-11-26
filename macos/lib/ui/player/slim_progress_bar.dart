// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ohos_runtime.dart';
import '../apple_theme.dart';
import '../ios_liquid_glass.dart';

/// Persistent ultra-slim bottom progress indicator (`2.5lp`) visible ONLY when
/// playing VOD with full controls hidden (`!controlsVisible`) and not embedded/PiP.
class SlimProgressBar extends StatelessWidget {
  static const double defaultHeight = 2.5;

  final bool visible;
  final bool enabled;
  final bool isLive;
  final bool isEmbeddedOrPip;
  final int positionMs;
  final int durationMs;
  final int skipIntroSec;
  final int skipOutroSec;
  final double height;
  final bool reduceTransparency;

  const SlimProgressBar({
    super.key,
    required this.visible,
    required this.enabled,
    required this.isLive,
    required this.positionMs,
    required this.durationMs,
    this.isEmbeddedOrPip = false,
    this.skipIntroSec = 0,
    this.skipOutroSec = 0,
    this.height = defaultHeight,
    this.reduceTransparency = false,
  });

  bool get shouldShow =>
      !OhosRuntime.isOhos &&
      enabled &&
      visible &&
      !isLive &&
      !isEmbeddedOrPip &&
      durationMs > 0;

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos || !enabled || isLive || isEmbeddedOrPip || durationMs <= 0) {
      return const SizedBox.shrink();
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final effectiveReduceTransparency = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        MediaQuery.highContrastOf(context);
    final fraction =
        (positionMs / math.max(1, durationMs)).clamp(0.0, 1.0).toDouble();
    final introFraction = skipIntroSec > 0
        ? ((skipIntroSec * 1000) / durationMs).clamp(0.0, 1.0).toDouble()
        : null;
    final outroFraction = skipOutroSec > 0 && durationMs > skipOutroSec * 1000
        ? ((durationMs - skipOutroSec * 1000) / durationMs)
            .clamp(0.0, 1.0)
            .toDouble()
        : null;

    return IgnorePointer(
      child: AnimatedOpacity(
        key: const Key('player-slim-progress-bar'),
        opacity: visible ? 1.0 : 0.0,
        duration: Duration(milliseconds: reduceMotion ? 120 : 150),
        curve: reduceMotion ? Curves.linear : Curves.easeOut,
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: CustomPaint(
            painter: _SlimProgressPainter(
              progress: fraction,
              introMarker: introFraction,
              outroMarker: outroFraction,
              trackColor: effectiveReduceTransparency
                  ? const Color(0x66FFFFFF)
                  : const Color(0x33FFFFFF),
              fillColor: effectiveReduceTransparency
                  ? Colors.white
                  : AppleColors.systemBlue.withValues(alpha: 0.92),
              markerColor: const Color(0xCCFFD60A),
            ),
          ),
        ),
      ),
    );
  }
}

class _SlimProgressPainter extends CustomPainter {
  final double progress;
  final double? introMarker;
  final double? outroMarker;
  final Color trackColor;
  final Color fillColor;
  final Color markerColor;

  const _SlimProgressPainter({
    required this.progress,
    required this.introMarker,
    required this.outroMarker,
    required this.trackColor,
    required this.fillColor,
    required this.markerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final trackPaint = Paint()..color = trackColor;
    canvas.drawRect(Offset.zero & size, trackPaint);

    final fillWidth = (size.width * progress).clamp(0.0, size.width);
    if (fillWidth > 0) {
      final fillPaint = Paint()..color = fillColor;
      canvas.drawRect(Rect.fromLTWH(0, 0, fillWidth, size.height), fillPaint);
    }

    final markerPaint = Paint()..color = markerColor;
    if (introMarker != null && introMarker! > 0.005 && introMarker! < 0.995) {
      final x = size.width * introMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
    if (outroMarker != null && outroMarker! > 0.005 && outroMarker! < 0.995) {
      final x = size.width * outroMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SlimProgressPainter old) =>
      old.progress != progress ||
      old.introMarker != introMarker ||
      old.outroMarker != outroMarker ||
      old.trackColor != trackColor ||
      old.fillColor != fillColor;
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'package:media_kit/media_kit.dart';

/// How the active subtitle track should be rendered on desktop libmpv builds.
enum SubtitleRenderMode {
  /// Subtitles explicitly disabled (`SubtitleTrack.no()`).
  none,

  /// Plain-text subtitles (SRT / WebVTT / tx3g / mov_text) rendered by Flutter
  /// `SubtitleView` in `player-subtitle-layer` strictly above `DanmuLayer`.
  flutterTextOverlay,

  /// Styled ASS/SSA tracks rendered natively by libass inside libmpv so top
  /// signs (`\an8`) and explicit typesetting (`\pos`) preserve their original
  /// coordinates while bottom dialogue lifts cleanly via `sub-pos`.
  mpvNativeAss,

  /// Image/bitmap tracks (Blu-ray PGS `hdmv_pgs_subtitle`, DVD VobSub, DVB,
  /// XSUB) rendered natively by libmpv and shifted vertically via `sub-pos`
  /// (which shifts bottom-half bitmaps upward while leaving top-half bitmaps in
  /// place).
  mpvNativeBitmap,
}

/// Pure geometry and track-classification helper that couples subtitle vertical
/// clearance to the actual measured bottom HUD controls height without altering
/// video framing, danmu bounds, or pointer/drag hit-test regions.
class SubtitleLayoutGeometry {
  SubtitleLayoutGeometry._();

  /// Matches `media_kit_video`'s default `SubtitleViewConfiguration.padding.bottom`.
  static const double defaultBottomPadding = 24.0;
  static const double defaultHorizontalPadding = 16.0;

  /// Extra visual breathing space between the lowest line of a 2-line subtitle
  /// and the top edge of the bottom progress bar / toolbar controls.
  static const double defaultHudClearanceGap = 16.0;

  /// Minimum `sub-pos` percentage allowed when shifting libmpv subtitles up so
  /// they never collide with the top half / center transport controls.
  static const int minMpvSubPos = 45;

  static bool isBitmapSubtitleTrack(SubtitleTrack track) {
    if (track.id == 'no' || track.id == 'auto') return false;
    if (track.image == true) return true;
    final codec = (track.codec ?? '').trim().toLowerCase();
    final decoder = (track.decoder ?? '').trim().toLowerCase();
    final combined = '$codec $decoder';
    if (combined.trim().isEmpty) return false;
    return combined.contains('pgs') ||
        combined.contains('hdmv_pgs') ||
        combined.contains('dvd_subtitle') ||
        combined.contains('vobsub') ||
        combined.contains('dvb_subtitle') ||
        combined.contains('xsub') ||
        combined.contains('bitmap');
  }

  static bool isAssSubtitleTrack(SubtitleTrack track) {
    if (track.id == 'no' || track.id == 'auto') return false;
    final codec = (track.codec ?? '').trim().toLowerCase();
    final decoder = (track.decoder ?? '').trim().toLowerCase();
    return codec == 'ass' ||
        codec == 'ssa' ||
        codec.endsWith('/ass') ||
        codec.endsWith('/ssa') ||
        decoder.contains('libass') ||
        (codec.isEmpty &&
            ((track.title ?? '').toLowerCase().endsWith('.ass') ||
                (track.title ?? '').toLowerCase().endsWith('.ssa')));
  }

  static SubtitleRenderMode classifyTrack(SubtitleTrack? track) {
    if (track == null || track.id == 'no') {
      return SubtitleRenderMode.none;
    }
    if (isBitmapSubtitleTrack(track)) {
      return SubtitleRenderMode.mpvNativeBitmap;
    }
    if (isAssSubtitleTrack(track)) {
      return SubtitleRenderMode.mpvNativeAss;
    }
    return SubtitleRenderMode.flutterTextOverlay;
  }

  /// Resolves the concrete [SubtitleTrack] currently selected, dereferencing
  /// `SubtitleTrack.auto()` using libmpv's live `sid` property (when available)
  /// or the track list's default concrete subtitle track.
  static SubtitleTrack? resolveActiveTrack({
    required SubtitleTrack selected,
    required List<SubtitleTrack> available,
    String? mpvSid,
  }) {
    if (selected.id == 'no') return SubtitleTrack.no();

    final concrete = available
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false);

    if (selected.id != 'auto' && selected.id.isNotEmpty) {
      for (final t in concrete) {
        if (t.id == selected.id) return t;
      }
      return selected;
    }

    final sid = (mpvSid ?? '').trim();
    if (sid == 'no' || sid == 'false') {
      return SubtitleTrack.no();
    }
    if (sid.isNotEmpty && sid != 'auto') {
      for (final t in concrete) {
        if (t.id == sid) return t;
      }
    }
    for (final t in concrete) {
      if (t.isDefault == true) return t;
    }
    return concrete.isNotEmpty ? concrete.first : null;
  }

  /// Bottom padding for Flutter's `player-subtitle-layer` (`SubtitleView`).
  ///
  /// When [hudControlsVisible] is false (including when controls are hidden or
  /// only the slim progress line is displayed), returns the baseline bottom
  /// padding so subtitles rest in their original position.
  static double computeTextOverlayBottomPadding({
    required bool hudControlsVisible,
    required double measuredBottomBarHeight,
    double bottomSafeInset = 0.0,
    double basePadding = defaultBottomPadding,
    double clearanceGap = defaultHudClearanceGap,
  }) {
    final baseline = math.max(basePadding, basePadding + bottomSafeInset);
    if (!hudControlsVisible) return baseline;
    final safeMeasured = math.max(0.0, measuredBottomBarHeight);
    if (safeMeasured <= 0.0) return baseline;
    return math.max(baseline, safeMeasured + clearanceGap);
  }

  /// Exact rectangle occupied by the visible video surface inside [viewport]
  /// for [fit], matching Flutter's `FittedBox` / `media_kit_video` `Video`.
  static Rect computeDisplayedVideoRect({
    required Size viewport,
    required int videoWidth,
    required int videoHeight,
    required BoxFit fit,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return Rect.zero;
    }
    final vw = videoWidth > 0 ? videoWidth.toDouble() : viewport.width;
    final vh = videoHeight > 0 ? videoHeight.toDouble() : viewport.height;
    final fitted = applyBoxFit(fit, Size(vw, vh), viewport);
    final dest = fitted.destination;
    final left = (viewport.width - dest.width) / 2.0;
    final top = (viewport.height - dest.height) / 2.0;
    return Rect.fromLTWH(left, top, dest.width, dest.height);
  }

  /// Full unclipped rectangle of the scaled source video frame in viewport
  /// coordinates for [fit].
  ///
  /// For `BoxFit.contain` and `BoxFit.fill`, this equals
  /// [computeDisplayedVideoRect]. For `BoxFit.cover` (crop), `applyBoxFit`
  /// returns the visible cropped `source` slice mapped onto `destination`; the
  /// full source frame extends beyond [viewport] (`top < 0`,
  /// `bottom > viewport.height` when vertically cropped), which determines how
  /// libmpv's `sub-pos` (expressed in source video frame height) maps to
  /// visible screen coordinates.
  static Rect computeRenderedVideoRect({
    required Size viewport,
    required int videoWidth,
    required int videoHeight,
    required BoxFit fit,
  }) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return Rect.zero;
    }
    final vw = videoWidth > 0 ? videoWidth.toDouble() : viewport.width;
    final vh = videoHeight > 0 ? videoHeight.toDouble() : viewport.height;
    final fitted = applyBoxFit(fit, Size(vw, vh), viewport);
    if (fitted.source.width <= 0 || fitted.source.height <= 0) {
      return computeDisplayedVideoRect(
        viewport: viewport,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        fit: fit,
      );
    }
    final scaleX = fitted.destination.width / fitted.source.width;
    final scaleY = fitted.destination.height / fitted.source.height;
    final fullW = vw * scaleX;
    final fullH = vh * scaleY;
    final left = (viewport.width - fullW) / 2.0;
    final top = (viewport.height - fullH) / 2.0;
    return Rect.fromLTWH(left, top, fullW, fullH);
  }

  /// Computes libmpv's `sub-pos` (`45..100`, where `100` is native baseline) so
  /// bottom-aligned ASS dialogue and bottom-half PGS bitmap subtitles lift above
  /// the bottom HUD controls while ASS `\an8` top signs and top-half bitmaps
  /// remain untouched at their original coordinates — across `BoxFit.contain`,
  /// `BoxFit.cover` (crop), and `BoxFit.fill`.
  static int computeMpvSubPos({
    required Size viewport,
    required int videoWidth,
    required int videoHeight,
    required BoxFit fit,
    required bool hudControlsVisible,
    required double measuredBottomBarHeight,
    double clearanceGap = defaultHudClearanceGap,
  }) {
    if (!hudControlsVisible ||
        measuredBottomBarHeight <= 0.0 ||
        viewport.height <= 0.0) {
      return 100;
    }
    final fullVideoRect = computeRenderedVideoRect(
      viewport: viewport,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      fit: fit,
    );
    if (fullVideoRect.height <= 0.0) return 100;

    // Positive when letterboxed (black bar below video); negative in cover crop
    // where the bottom of the source frame is clipped below the viewport edge.
    final bottomMarginOrCrop = viewport.height - fullVideoRect.bottom;
    final neededAboveVideoBottom =
        (measuredBottomBarHeight + clearanceGap) - bottomMarginOrCrop;
    if (neededAboveVideoBottom <= 0.0) {
      return 100;
    }

    final liftPercent = (neededAboveVideoBottom / fullVideoRect.height) * 100.0;
    return (100.0 - liftPercent).floor().clamp(minMpvSubPos, 100);
  }
}

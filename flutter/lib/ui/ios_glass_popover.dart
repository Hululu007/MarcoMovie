import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'motion/ios27_springs.dart';

/// Resolves the global screen [Rect] of a widget attached to [key], or `null`
/// if it is not yet laid out or mounted.
Rect? rectForGlobalKey(GlobalKey? key) {
  final ctx = key?.currentContext;
  if (ctx == null) return null;
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final topLeft = box.localToGlobal(Offset.zero);
  return topLeft & box.size;
}

/// Tracks how many floating Liquid Glass popovers are currently open so active
/// overlays (such as the video player HUD) pause auto-hide while a popover is
/// displayed.
final ValueNotifier<int> activeIosGlassPopoverCount = ValueNotifier<int>(0);

/// Shows an iOS 27 arrowless fluid morphing Liquid Glass menu anchored to
/// [anchorRect].
///
/// Morphs seamlessly out of [anchorRect] using [Ios27Spring.bouncy]
/// (`Spring(duration: 0.44, bounce: 0.24)`) into a continuous `24pt` rounded
/// glass capsule menu with specular rim optics, and collapses back toward
/// [anchorRect] on dismissal. Automatically degrades to a `150ms` opacity fade
/// when `MediaQuery.disableAnimationsOf(context)` is enabled.
Future<T?> showIosGlassPopover<T>({
  required BuildContext context,
  required Rect? anchorRect,
  required String title,
  required WidgetBuilder builder,
  double maxWidth = 306,
  double maxHeight = 468,
  bool forceDark = true,
  Widget? trailing,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(8, 4, 8, 8),
}) {
  return Navigator.of(context, rootNavigator: false).push<T>(
    _Ios27MorphingPopoverRoute<T>(
      anchorRect: anchorRect,
      title: title,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      forceDark: forceDark,
      trailing: trailing,
      contentPadding: contentPadding,
      builder: builder,
      barrierLabelText:
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _Ios27MorphingPopoverRoute<T> extends PopupRoute<T> {
  final Rect? anchorRect;
  final String title;
  final double maxWidth;
  final double maxHeight;
  final bool forceDark;
  final Widget? trailing;
  final EdgeInsetsGeometry contentPadding;
  final WidgetBuilder builder;
  final String barrierLabelText;

  _Ios27MorphingPopoverRoute({
    required this.anchorRect,
    required this.title,
    required this.maxWidth,
    required this.maxHeight,
    required this.forceDark,
    required this.trailing,
    required this.contentPadding,
    required this.builder,
    required this.barrierLabelText,
  });

  @override
  Color? get barrierColor => forceDark
      ? Colors.black.withValues(alpha: 0.16)
      : Colors.black.withValues(alpha: 0.08);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => barrierLabelText;

  @override
  Duration get transitionDuration => Ios27Spring.bouncy.nominalDuration;

  @override
  Duration get reverseTransitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _IosGlassPopoverOverlay(
      routeAnimation: animation,
      anchorRect: anchorRect,
      title: title,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      forceDark: forceDark,
      trailing: trailing,
      contentPadding: contentPadding,
      builder: builder,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Ios27ConcentricGeometry.isReduceMotion(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.linear,
          reverseCurve: Curves.linear,
        ),
        child: child,
      );
    }
    return child;
  }
}

/// Resolved non-overlapping geometry for [showIosGlassPopover].
@immutable
class IosGlassPopoverLayout {
  final bool useSheetFallback;
  final double width;
  final double maxHeight;
  final double left;
  final double? top;
  final double? bottom;
  final Alignment morphAlignment;

  const IosGlassPopoverLayout({
    required this.useSheetFallback,
    required this.width,
    required this.maxHeight,
    required this.left,
    required this.top,
    required this.bottom,
    required this.morphAlignment,
  });

  /// Returns the conservative bounding rectangle occupied by this popover
  /// given [screenHeight] (used in unit/widget geometry tests to assert zero
  /// anchor occlusion).
  Rect boundingRect(double screenHeight) {
    final resolvedTop =
        top ?? (screenHeight - (bottom ?? 0.0) - maxHeight);
    return Rect.fromLTWH(left, resolvedTop, width, maxHeight);
  }
}

/// Pure safe-area net-clearance layout solver for [showIosGlassPopover].
///
/// Computes actual net clearance on all 4 sides of [anchorRect] inside the
/// screen's safe area (`safe`), chooses a non-overlapping placement and clamped
/// size so the popover NEVER covers [anchorRect], and falls back to a compact
/// scrollable bottom sheet (`useSheetFallback: true`) whenever no
/// non-overlapping side has enough clearance for comfortable 4-item interaction.
@visibleForTesting
IosGlassPopoverLayout computeIosGlassPopoverLayout({
  required Size screen,
  required EdgeInsets safe,
  required Rect? anchorRect,
  required double maxWidth,
  required double maxHeight,
}) {
  final isCompactHeight = screen.height < 480;
  final edgeGap = isCompactHeight ? 6.0 : (screen.width <= 360 ? 8.0 : 12.0);
  const anchorGap = 6.0;
  const minComfortableW = 208.0;
  final minComfortableH = isCompactHeight ? 212.0 : 232.0;

  final safeLeft = safe.left + edgeGap;
  final safeRight = math.max(safeLeft + 160.0, screen.width - safe.right - edgeGap);
  final safeTop = safe.top + edgeGap;
  final safeBottom =
      math.max(safeTop + 160.0, screen.height - safe.bottom - edgeGap);

  final availableW = (safeRight - safeLeft).clamp(160.0, screen.width);
  final fullSafeSpan = (safeBottom - safeTop).clamp(160.0, screen.height * 0.94);

  if (anchorRect == null) {
    final sheetW = math.min(maxWidth, availableW);
    final sheetH = math.min(maxHeight, fullSafeSpan);
    final left = safeLeft + (availableW - sheetW) * 0.5;
    final top = safeTop + (fullSafeSpan - sheetH) * 0.5;
    return IosGlassPopoverLayout(
      useSheetFallback: false,
      width: sheetW,
      maxHeight: sheetH,
      left: left,
      top: top,
      bottom: null,
      morphAlignment: Alignment.center,
    );
  }

  final anchor = anchorRect;
  final spaceAbove = (anchor.top - anchorGap) - safeTop;
  final spaceBelow = safeBottom - (anchor.bottom + anchorGap);
  final spaceLeft = (anchor.left - anchorGap) - safeLeft;
  final spaceRight = safeRight - (anchor.right + anchorGap);

  final isSideEdgeAnchor =
      (anchor.center.dx > screen.width * 0.72 ||
          anchor.center.dx < screen.width * 0.28) &&
      anchor.center.dy >= screen.height * 0.22 &&
      anchor.center.dy <= screen.height * 0.78;

  IosGlassPopoverLayout? tryPlaceLeft() {
    if (spaceLeft < minComfortableW || fullSafeSpan < 160.0) return null;
    final bubbleW = math.min(maxWidth, spaceLeft);
    final bubbleH = math.min(maxHeight, fullSafeSpan);
    final left = (anchor.left - anchorGap - bubbleW)
        .clamp(
          safeLeft,
          math.max(safeLeft, anchor.left - anchorGap - bubbleW),
        )
        .toDouble();
    final top = (anchor.center.dy - bubbleH * 0.5)
        .clamp(safeTop, math.max(safeTop, safeBottom - bubbleH))
        .toDouble();
    return IosGlassPopoverLayout(
      useSheetFallback: false,
      width: bubbleW,
      maxHeight: bubbleH,
      left: left,
      top: top,
      bottom: null,
      morphAlignment: const Alignment(1.0, 0.0),
    );
  }

  IosGlassPopoverLayout? tryPlaceRight() {
    if (spaceRight < minComfortableW || fullSafeSpan < 160.0) return null;
    final bubbleW = math.min(maxWidth, spaceRight);
    final bubbleH = math.min(maxHeight, fullSafeSpan);
    final left = anchor.right + anchorGap;
    final top = (anchor.center.dy - bubbleH * 0.5)
        .clamp(safeTop, math.max(safeTop, safeBottom - bubbleH))
        .toDouble();
    return IosGlassPopoverLayout(
      useSheetFallback: false,
      width: bubbleW,
      maxHeight: bubbleH,
      left: left,
      top: top,
      bottom: null,
      morphAlignment: const Alignment(-1.0, 0.0),
    );
  }

  IosGlassPopoverLayout? tryPlaceVertical({required bool below}) {
    final clearance = below ? spaceBelow : spaceAbove;
    if (clearance < minComfortableH) return null;
    final bubbleW = math.min(maxWidth, availableW);
    final bubbleH = math.min(maxHeight, clearance);
    final left = (anchor.center.dx - bubbleW * 0.5)
        .clamp(safeLeft, math.max(safeLeft, safeRight - bubbleW))
        .toDouble();
    final normX = (((anchor.center.dx - left) / math.max(bubbleW, 1.0)) * 2.0 - 1.0)
        .clamp(-1.0, 1.0);
    if (below) {
      return IosGlassPopoverLayout(
        useSheetFallback: false,
        width: bubbleW,
        maxHeight: bubbleH,
        left: left,
        top: anchor.bottom + anchorGap,
        bottom: null,
        morphAlignment: Alignment(normX, -1.0),
      );
    }
    return IosGlassPopoverLayout(
      useSheetFallback: false,
      width: bubbleW,
      maxHeight: bubbleH,
      left: left,
      top: null,
      bottom: screen.height - (anchor.top - anchorGap),
      morphAlignment: Alignment(normX, 1.0),
    );
  }

  // 1. Side-edge buttons (e.g., symmetrical right-edge AI button) strongly
  //    prefer opening horizontally away from the anchor so they never cover it.
  if (isSideEdgeAnchor) {
    final sidePrimary = anchor.center.dx > screen.width * 0.5
        ? tryPlaceLeft()
        : tryPlaceRight();
    if (sidePrimary != null) return sidePrimary;
    final sideSecondary = anchor.center.dx > screen.width * 0.5
        ? tryPlaceRight()
        : tryPlaceLeft();
    if (sideSecondary != null) return sideSecondary;
  }

  // 2. Top/bottom anchors pick whichever vertical side has larger clearance,
  //    strictly honoring net clearance without overlapping the anchor.
  final preferBelow = spaceBelow >= spaceAbove;
  final primaryVert = tryPlaceVertical(below: preferBelow);
  if (primaryVert != null) return primaryVert;
  final secondaryVert = tryPlaceVertical(below: !preferBelow);
  if (secondaryVert != null) return secondaryVert;

  // 3. Compact-height landscape screens (e.g. 375pt tall iPhone) where vertical
  //    clearance above/below the toolbar is tight: try placing horizontally
  //    beside the anchor using the full safe height!
  final preferLeft = spaceLeft >= spaceRight;
  final sideAlt1 = preferLeft ? tryPlaceLeft() : tryPlaceRight();
  if (sideAlt1 != null) return sideAlt1;
  final sideAlt2 = preferLeft ? tryPlaceRight() : tryPlaceLeft();
  if (sideAlt2 != null) return sideAlt2;

  // 4. No non-overlapping popover direction has enough clearance -> downgrade
  //    cleanly to a compact scrollable bottom sheet!
  final sheetW = math.min(math.max(maxWidth, 320.0), availableW);
  final sheetH = math.min(maxHeight, fullSafeSpan);
  final sheetLeft = safeLeft + (availableW - sheetW) * 0.5;
  return IosGlassPopoverLayout(
    useSheetFallback: true,
    width: sheetW,
    maxHeight: sheetH,
    left: sheetLeft,
    top: null,
    bottom: safe.bottom + edgeGap,
    morphAlignment: Alignment.bottomCenter,
  );
}

class _IosGlassPopoverOverlay extends StatefulWidget {
  final Animation<double> routeAnimation;
  final Rect? anchorRect;
  final String title;
  final double maxWidth;
  final double maxHeight;
  final bool forceDark;
  final Widget? trailing;
  final EdgeInsetsGeometry contentPadding;
  final WidgetBuilder builder;

  const _IosGlassPopoverOverlay({
    required this.routeAnimation,
    required this.anchorRect,
    required this.title,
    required this.maxWidth,
    required this.maxHeight,
    required this.forceDark,
    required this.trailing,
    required this.contentPadding,
    required this.builder,
  });

  @override
  State<_IosGlassPopoverOverlay> createState() =>
      _IosGlassPopoverOverlayState();
}

class _IosGlassPopoverOverlayState extends State<_IosGlassPopoverOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _morphCtrl;
  bool _startedEnter = false;
  bool _reversing = false;

  @override
  void initState() {
    super.initState();
    activeIosGlassPopoverCount.value++;
    _morphCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
    widget.routeAnimation.addStatusListener(_onRouteStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_startedEnter) {
      _startedEnter = true;
      final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
      Ios27Spring.animate(
        _morphCtrl,
        spring: Ios27Spring.bouncy,
        target: 1.0,
        disableAnimations: reduceMotion,
      );
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.reverse && !_reversing) {
      _reversing = true;
      final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
      Ios27Spring.animate(
        _morphCtrl,
        spring: Ios27Spring.smooth,
        target: 0.0,
        disableAnimations: reduceMotion,
      );
    } else if (status == AnimationStatus.forward && _reversing) {
      _reversing = false;
      final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
      Ios27Spring.animate(
        _morphCtrl,
        spring: Ios27Spring.bouncy,
        target: 1.0,
        disableAnimations: reduceMotion,
      );
    }
  }

  @override
  void dispose() {
    widget.routeAnimation.removeStatusListener(_onRouteStatus);
    _morphCtrl.dispose();
    if (activeIosGlassPopoverCount.value > 0) {
      activeIosGlassPopoverCount.value--;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anchorRect = widget.anchorRect;
    final title = widget.title;
    final maxWidth = widget.maxWidth;
    final maxHeight = widget.maxHeight;
    final forceDark = widget.forceDark;
    final trailing = widget.trailing;
    final contentPadding = widget.contentPadding;
    final builder = widget.builder;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    const menuRadius = 24.0;

    final layout = computeIosGlassPopoverLayout(
      screen: screen,
      safe: safe,
      anchorRect: anchorRect,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
    final bubbleW = layout.width;
    final bubbleMaxH = layout.maxHeight;
    final left = layout.left;
    final morphAlignment = layout.morphAlignment;

    final isDark = forceDark || ApplePalette.isDarkOf(context);
    final reduce = IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);

    final titleColor = isDark ? Colors.white : const Color(0xFF111114);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final specularBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.24)
        : Colors.black.withValues(alpha: 0.09);

    final bubble = Theme(
      data: Theme.of(context).copyWith(
        brightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          key: ValueKey<String>(
            layout.useSheetFallback
                ? 'ios-glass-popover-sheet-fallback'
                : 'ios-glass-popover-surface',
          ),
          constraints: BoxConstraints(
            minWidth: math.min(200, bubbleW),
            maxWidth: bubbleW,
            maxHeight: bubbleMaxH,
          ),
          child: AnimatedBuilder(
            animation: _morphCtrl,
            builder: (context, menuChild) {
              const anchorGap = 6.0;
              final anchorHeight = anchorRect?.height ?? 40.0;
              final opensDownward = layout.top != null;
              final rawT = _morphCtrl.value;
              final clampedT = rawT.clamp(0.0, 1.0);
              final opacity = reduceMotion
                  ? clampedT
                  : (rawT / 0.34).clamp(0.0, 1.0);
              final scale = reduceMotion
                  ? 1.0
                  : lerpDouble(0.32, 1.0, rawT)!.clamp(0.25, 1.12);
              final currentRadius = reduceMotion
                  ? menuRadius
                  : lerpDouble(
                      math.min(anchorHeight * 0.5, menuRadius),
                      menuRadius,
                      clampedT,
                    )!;
              final translateDy = reduceMotion
                  ? 0.0
                  : (opensDownward ? -anchorGap : anchorGap) * (1.0 - clampedT);

              return Opacity(
                opacity: opacity,
                child: Transform.translate(
                  offset: Offset(0.0, translateDy),
                  child: Transform.scale(
                    scale: scale,
                    alignment: morphAlignment,
                    child: DecoratedBox(
                      key: const Key('ios-glass-popover-bubble'),
                      decoration: ShapeDecoration(
                        shape: Ios27ConcentricGeometry.continuousShape(
                          radius: currentRadius,
                          side: BorderSide(
                            color: specularBorderColor,
                            width: 0.75,
                          ),
                        ),
                        shadows: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: (isDark ? 0.44 : 0.16) * clampedT,
                            ),
                            blurRadius: 28,
                            spreadRadius: -4,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: ClipPath(
                        clipper: ShapeBorderClipper(
                          shape: Ios27ConcentricGeometry.continuousShape(
                            radius: currentRadius,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: LiquidGlass(
                          borderRadius: currentRadius,
                          blur: 24,
                          tint: isDark
                              ? const Color(0x001E1E22)
                              : const Color(0x00FFFFFF),
                          rimStrength: 1.0,
                          elevated: false,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: reduce
                                  ? Colors.transparent
                                  : (isDark
                                      ? const Color(0x8A15161B)
                                      : const Color(0x9EFFFFFF)),
                            ),
                            child: menuChild,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title.isNotEmpty || trailing != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: titleColor,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        if (trailing != null) trailing,
                      ],
                    ),
                  ),
                  Divider(height: 1, thickness: 0.5, color: dividerColor),
                ],
                Flexible(
                  child: Padding(
                    padding: contentPadding,
                    child: Builder(builder: builder),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final Widget positioned = layout.top != null
        ? Positioned(
            left: left,
            top: layout.top,
            child: bubble,
          )
        : Positioned(
            left: left,
            bottom: layout.bottom ?? (safe.bottom + 8.0),
            child: bubble,
          );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.expand(),
          ),
        ),
        positioned,
      ],
    );
  }
}

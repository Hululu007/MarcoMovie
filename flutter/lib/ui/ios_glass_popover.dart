import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';

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

/// Shows a compact, native-style Liquid Glass bubble popover anchored to
/// [anchorRect] rather than a full-screen covering modal sheet.
///
/// The bubble automatically opens below or above [anchorRect] depending on
/// available viewport space, stays clamped inside the screen safe area, paints
/// a crisp directional pointer notch aimed at the trigger button, and animates
/// with a spring scale-from-anchor reveal.
Future<T?> showIosGlassPopover<T>({
  required BuildContext context,
  required Rect? anchorRect,
  required String title,
  required WidgetBuilder builder,
  double maxWidth = 300,
  double maxHeight = 320,
  bool forceDark = true,
  Widget? trailing,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(12, 6, 12, 12),
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: forceDark
        ? Colors.black.withValues(alpha: 0.16)
        : Colors.black.withValues(alpha: 0.08),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _IosGlassPopoverOverlay(
        anchorRect: anchorRect,
        title: title,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        forceDark: forceDark,
        trailing: trailing,
        contentPadding: contentPadding,
        builder: builder,
      );
    },
    transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(dialogContext)) {
        return child;
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.2, 1.08, 0.32, 1.0),
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
          alignment: _popoverScaleAlignment(dialogContext, anchorRect),
          child: child,
        ),
      );
    },
  );
}

Alignment _popoverScaleAlignment(BuildContext context, Rect? anchorRect) {
  if (anchorRect == null) return Alignment.center;
  final size = MediaQuery.sizeOf(context);
  if (size.width <= 0 || size.height <= 0) return Alignment.center;
  final ax = ((anchorRect.center.dx / size.width) * 2 - 1).clamp(-1.0, 1.0);
  final ay = ((anchorRect.center.dy / size.height) * 2 - 1).clamp(-1.0, 1.0);
  return Alignment(ax, ay);
}

class _IosGlassPopoverOverlay extends StatelessWidget {
  final Rect? anchorRect;
  final String title;
  final double maxWidth;
  final double maxHeight;
  final bool forceDark;
  final Widget? trailing;
  final EdgeInsetsGeometry contentPadding;
  final WidgetBuilder builder;

  const _IosGlassPopoverOverlay({
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
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    const edgeGap = 12.0;
    const arrowHeight = 8.0;
    const anchorGap = 8.0;

    final safeLeft = safe.left + edgeGap;
    final safeRight = math.max(safeLeft + 180.0, screen.width - safe.right - edgeGap);
    final safeTop = safe.top + edgeGap;
    final safeBottom = math.max(safeTop + 140.0, screen.height - safe.bottom - edgeGap);

    final availableW = (safeRight - safeLeft).clamp(180.0, screen.width);
    final bubbleW = math.min(maxWidth, availableW);
    final anchor = anchorRect ??
        Rect.fromCenter(
          center: Offset(screen.width / 2, screen.height * 0.42),
          width: 40,
          height: 40,
        );

    final spaceBelow = safeBottom - (anchor.bottom + anchorGap);
    final spaceAbove = (anchor.top - anchorGap) - safeTop;
    final showBelow = spaceBelow >= math.min(maxHeight, 210) ||
        spaceBelow >= spaceAbove;

    final maxAvailableH =
        (showBelow ? spaceBelow : spaceAbove) - arrowHeight;
    final bubbleMaxH = math.min(
      maxHeight,
      maxAvailableH.clamp(120.0, screen.height * 0.72),
    );

    final rawLeft = anchor.center.dx - bubbleW / 2;
    final left = rawLeft.clamp(safeLeft, safeRight - bubbleW);
    final arrowX = (anchor.center.dx - left).clamp(24.0, bubbleW - 24.0);

    final isDark = forceDark || ApplePalette.isDarkOf(context);
    final reduce = IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);

    final fillColor = isDark
        ? (reduce ? const Color(0xF51C1C1F) : const Color(0xC218181D))
        : (reduce ? const Color(0xFAFFFFFF) : const Color(0xDCFFFFFF));
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.22)
        : Colors.black.withValues(alpha: 0.09);
    final titleColor = isDark ? Colors.white : const Color(0xFF111114);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    final bubble = Theme(
      data: Theme.of(context).copyWith(
        brightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: math.min(220, bubbleW),
            maxWidth: bubbleW,
            maxHeight: bubbleMaxH,
          ),
          child: Container(
            key: const Key('ios-glass-popover-bubble'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.16),
                  blurRadius: 28,
                  spreadRadius: -4,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: LiquidGlass(
              borderRadius: 20,
              blur: 24,
              tint: isDark ? const Color(0x001E1E22) : const Color(0x00FFFFFF),
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (title.isNotEmpty || trailing != null) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 11, 10, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.1,
                                ),
                              ),
                            ),
                            if (trailing != null) trailing!,
                          ],
                        ),
                      ),
                      Divider(height: 1, thickness: 0.6, color: dividerColor),
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
        ),
      ),
    );

    final pointer = CustomPaint(
      size: Size(bubbleW, arrowHeight),
      painter: _PopoverArrowPainter(
        tipX: arrowX,
        pointsUp: showBelow,
        fillColor: fillColor,
        borderColor: borderColor,
      ),
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: showBelow ? [pointer, bubble] : [bubble, pointer],
    );

    final positioned = showBelow
        ? Positioned(
            left: left,
            top: (anchor.bottom + anchorGap).clamp(safeTop, safeBottom - 120),
            child: column,
          )
        : Positioned(
            left: left,
            bottom: (screen.height - (anchor.top - anchorGap))
                .clamp(safe.bottom + edgeGap, screen.height - safeTop - 120),
            child: column,
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

class _PopoverArrowPainter extends CustomPainter {
  final double tipX;
  final bool pointsUp;
  final Color fillColor;
  final Color borderColor;

  const _PopoverArrowPainter({
    required this.tipX,
    required this.pointsUp,
    required this.fillColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const halfBase = 8.5;
    final path = Path();
    if (pointsUp) {
      path.moveTo(tipX - halfBase, size.height);
      path.lineTo(tipX, 1.0);
      path.lineTo(tipX + halfBase, size.height);
    } else {
      path.moveTo(tipX - halfBase, 0.0);
      path.lineTo(tipX, size.height - 1.0);
      path.lineTo(tipX + halfBase, 0.0);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );

    final strokePath = Path();
    if (pointsUp) {
      strokePath.moveTo(tipX - halfBase, size.height);
      strokePath.lineTo(tipX, 1.0);
      strokePath.lineTo(tipX + halfBase, size.height);
    } else {
      strokePath.moveTo(tipX - halfBase, 0.0);
      strokePath.lineTo(tipX, size.height - 1.0);
      strokePath.lineTo(tipX + halfBase, 0.0);
    }
    canvas.drawPath(
      strokePath,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PopoverArrowPainter old) =>
      old.tipX != tipX ||
      old.pointsUp != pointsUp ||
      old.fillColor != fillColor ||
      old.borderColor != borderColor;
}

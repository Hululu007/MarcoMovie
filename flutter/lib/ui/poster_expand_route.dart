import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'poster_image.dart';

/// iOS Apple TV / App Store style shared-container route transition:
///
/// - **Push (expand)**: Starts from the tapped poster card's exact screen
///   [Rect] and [sourceBorderRadius], smoothly expanding outward into the full
///   immersive [DetailScreen] while the poster cross-morphs into the hero.
/// - **Pop (collapse)**: Queries [sourceRectResolver] live so the entire
///   [DetailScreen] implodes smoothly right back into the original poster
///   card's exact on-screen position while keeping the underlying list scroll
///   position untouched.
/// - **Interactive edge swipe-back**: Supports dragging horizontally from the
///   left screen edge on iOS to collapse back smoothly in real time.
class PosterExpandRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Rect initialSourceRect;
  final Rect? Function()? sourceRectResolver;
  final double sourceBorderRadius;
  final String posterUrl;
  final String title;
  final String year;

  PosterExpandRoute({
    required this.builder,
    required this.initialSourceRect,
    this.sourceRectResolver,
    this.sourceBorderRadius = 14.0,
    this.posterUrl = '',
    this.title = '',
    this.year = '',
    super.settings,
  });

  /// Captures a live widget's screen-space [Rect] safely, returning null if
  /// unmounted, detached, zero-sized, or completely offscreen.
  static Rect? captureRect(BuildContext? ctx) {
    if (ctx == null || !ctx.mounted) return null;
    try {
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
      final size = ro.size;
      if (size.width < 8 || size.height < 8) return null;
      final offset = ro.localToGlobal(Offset.zero);
      if (!offset.dx.isFinite || !offset.dy.isFinite) return null;
      final rect = offset & size;
      final mq = MediaQuery.maybeSizeOf(ctx);
      if (mq != null) {
        final screenRect = Offset.zero & mq;
        if (!rect.overlaps(screenRect.inflate(60))) return null;
      }
      return rect;
    } catch (_) {
      return null;
    }
  }

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 360);

  void _setSwipeProgress(double value) {
    controller?.value = value.clamp(0.0, 1.0);
  }

  void _endSwipeGesture({required double velocity}) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;
    final shouldPop = velocity > 420.0 || ctrl.value < 0.72;
    if (shouldPop) {
      nav.pop();
    } else {
      ctrl.forward();
    }
    nav.didStopUserGesture();
  }

  void _cancelSwipeGesture() {
    controller?.forward();
    navigator?.didStopUserGesture();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _PosterExpandSwipeBackWrapper<T>(
      route: this,
      child: builder(context),
    );
  }

  Rect _resolveLiveTargetRect(Size screen) {
    final live = sourceRectResolver?.call();
    if (live != null &&
        live.width >= 8 &&
        live.height >= 8 &&
        live.overlaps((Offset.zero & screen).inflate(80))) {
      return live;
    }
    if (initialSourceRect.width >= 8 && initialSourceRect.height >= 8) {
      return initialSourceRect;
    }
    final w = screen.width * 0.28;
    final h = w * 1.48;
    return Rect.fromCenter(
      center: Offset(screen.width * 0.5, screen.height * 0.5),
      width: w,
      height: h,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }

    final screen = MediaQuery.sizeOf(context);
    final fullRect = Offset.zero & screen;

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, pageChild) {
        final rawT = animation.value.clamp(0.0, 1.0);

        // Once completely settled open, render full page cleanly with zero overhead.
        if (animation.status == AnimationStatus.completed && rawT >= 0.999) {
          return pageChild!;
        }

        final isReversing = animation.status == AnimationStatus.reverse;
        final rectT = isReversing
            ? Curves.easeInOutCubic.transform(rawT)
            : Curves.easeOutExpo.transform(rawT);
        final radiusT = Curves.easeOutCubic.transform(rawT);

        final sourceRect = _resolveLiveTargetRect(screen);
        final currentRect = Rect.lerp(sourceRect, fullRect, rectT) ?? fullRect;
        final currentRadius = lerpDouble(sourceBorderRadius, 0.0, radiusT) ?? 0.0;

        // Poster morph veil: smooth cross-dissolve between the small card
        // artwork and the full DetailScreen so expand & collapse read as one
        // continuous surface.
        final posterVeilOpacity = isReversing
            ? (1.0 - (rawT / 0.52).clamp(0.0, 1.0)) * 0.92
            : (1.0 - ((rawT - 0.04) / 0.34).clamp(0.0, 1.0));
        final contentOpacity = isReversing
            ? ((rawT - 0.06) / 0.44).clamp(0.0, 1.0)
            : ((rawT - 0.05) / 0.32).clamp(0.0, 1.0);
        final containerOpacity = isReversing
            ? (rawT / 0.14).clamp(0.0, 1.0)
            : (rawT / 0.10).clamp(0.0, 1.0);
        final backdropDim = (rawT * 0.42).clamp(0.0, 0.42);

        final scaleX =
            screen.width > 0 ? (currentRect.width / screen.width) : 1.0;
        final scaleY =
            screen.height > 0 ? (currentRect.height / screen.height) : 1.0;
        final contentScale =
            ((scaleX + scaleY) * 0.5).clamp(0.24, 1.0);

        return Stack(
          key: const Key('poster-expand-transition-stage'),
          fit: StackFit.expand,
          children: [
            // Soft depth scrim over the underlying Home page.
            IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: backdropDim),
              ),
            ),
            Positioned.fromRect(
              rect: currentRect,
              child: Opacity(
                opacity: containerOpacity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(currentRadius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.36 * rawT),
                        blurRadius: 28 * (1.0 - rawT * 0.5),
                        offset: Offset(0, 10 * (1.0 - rawT * 0.5)),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(currentRadius),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Full DetailScreen smoothly scaling inside the expanding/collapsing clip.
                        OverflowBox(
                          minWidth: screen.width,
                          maxWidth: screen.width,
                          minHeight: screen.height,
                          maxHeight: screen.height,
                          alignment: Alignment.topCenter,
                          child: Transform.scale(
                            scale: contentScale + (1.0 - contentScale) * rectT,
                            alignment: Alignment.topCenter,
                            child: Opacity(
                              opacity: contentOpacity,
                              child: pageChild,
                            ),
                          ),
                        ),
                        // Crisp card poster bridge layer for seamless visual continuity.
                        if (posterVeilOpacity > 0.01)
                          IgnorePointer(
                            child: Opacity(
                              opacity: posterVeilOpacity.clamp(0.0, 1.0),
                              child: PosterImage(
                                url: posterUrl,
                                title: title,
                                year: year,
                                highRes: true,
                                fit: BoxFit.cover,
                                fadeIn: false,
                                placeholder: const ColoredBox(
                                  color: Color(0xFF14161D),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Interactive left-edge horizontal swipe-back gesture detector so iOS users
/// can swipe back from the screen edge and watch [DetailScreen] implode right
/// back into the originating poster card in real time.
class _PosterExpandSwipeBackWrapper<T> extends StatefulWidget {
  final PosterExpandRoute<T> route;
  final Widget child;

  const _PosterExpandSwipeBackWrapper({
    required this.route,
    required this.child,
  });

  @override
  State<_PosterExpandSwipeBackWrapper<T>> createState() =>
      _PosterExpandSwipeBackWrapperState<T>();
}

class _PosterExpandSwipeBackWrapperState<T>
    extends State<_PosterExpandSwipeBackWrapper<T>> {
  bool _dragging = false;
  double _dragDistance = 0.0;

  void _onHorizontalDragStart(DragStartDetails details) {
    if (widget.route.isFirst ||
        !widget.route.isCurrent ||
        widget.route.navigator == null ||
        widget.route.navigator!.userGestureInProgress) {
      return;
    }
    if (details.globalPosition.dx > 28.0) return;
    _dragging = true;
    _dragDistance = 0.0;
    widget.route.navigator!.didStartUserGesture();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _dragDistance = (_dragDistance + details.delta.dx).clamp(0.0, width);
    final progress = (1.0 - (_dragDistance / width)).clamp(0.0, 1.0);
    widget.route._setSwipeProgress(progress);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    widget.route._endSwipeGesture(velocity: details.primaryVelocity ?? 0.0);
  }

  void _onHorizontalDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    widget.route._cancelSwipeGesture();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 24,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: _onHorizontalDragCancel,
          ),
        ),
      ],
    );
  }
}

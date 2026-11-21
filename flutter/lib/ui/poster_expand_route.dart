import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Tracks the currently expanding/collapsing poster card ID so the originating
/// card on the Home screen hides itself while in-flight (preserving its exact
/// layout [RenderBox] for live return-rect lookup) — preventing any stationary
/// duplicate ghost image behind the flying container.
class PosterExpandRegistry {
  PosterExpandRegistry._();

  static final ValueNotifier<String?> activeCardId = ValueNotifier<String?>(null);
}

/// Wraps a clickable poster card so it hides cleanly without collapsing layout
/// space while its [PosterExpandRoute] is actively flying or open.
class PosterExpandSourceCard extends StatelessWidget {
  final String cardId;
  final Widget child;

  const PosterExpandSourceCard({
    super.key,
    required this.cardId,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: PosterExpandRegistry.activeCardId,
      child: child,
      builder: (context, activeId, cardChild) {
        final hidden = activeId != null && activeId == cardId;
        return Visibility(
          visible: !hidden,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: cardChild!,
        );
      },
    );
  }
}

/// Real physics [SpringSimulation]-backed curve delivering authentic iOS 18
/// `UIViewControllerTransition.zoom` spring kinematics while staying 100%
/// compatible with interactive gesture scrubbing and Flutter widget tests.
class _AppleSpringCurve extends Curve {
  final SpringSimulation _sim;
  final double _durationSec;
  final double _endValue;

  _AppleSpringCurve({
    required double mass,
    required double stiffness,
    required double damping,
    required double durationSec,
  })  : _sim = SpringSimulation(
          SpringDescription(
            mass: mass,
            stiffness: stiffness,
            damping: damping,
          ),
          0.0,
          1.0,
          0.0,
        ),
        _durationSec = durationSec,
        _endValue = SpringSimulation(
          SpringDescription(
            mass: mass,
            stiffness: stiffness,
            damping: damping,
          ),
          0.0,
          1.0,
          0.0,
        ).x(durationSec);

  @override
  double transformInternal(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    final x = _sim.x(t * _durationSec);
    // Normalize tail smoothly so t = 1.0 lands on exact 1.0 with zero jump.
    return _endValue > 0.001 ? (x / _endValue) : x;
  }
}

/// Native iOS 18 `.zoom` / App Store card-expand shared-container route:
///
/// - **Zero ghosting ("拖影")**: Composites a single cached [RepaintBoundary]
///   of the destination [DetailScreen] locked 1:1 to the morphing container via
///   `FittedBox(fit: BoxFit.cover, alignment: Alignment.topCenter)` at full
///   `1.0` opacity — NO dual semi-transparent poster cross-fade and NO visible
///   duplicate source card underneath (`PosterExpandRegistry`).
/// - **Authentic Apple Spring Physics**: Uses real [SpringSimulation] curves
///   (snappy micro-overshoot spring on push, critically-damped precision snap
///   on pop back into the exact live [sourceRectResolver] position).
/// - **Interactive iOS Edge Swipe-Back**: Left-edge swipe detaches and rounds
///   the page interactively in 1:1 sync with the finger, then springs back into
///   the exact original card position on release.
class PosterExpandRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Rect initialSourceRect;
  final Rect? Function()? sourceRectResolver;
  final double sourceBorderRadius;
  final String? sourceCardId;
  final String posterUrl;
  final String title;
  final String year;

  // Calibrated to Apple iOS 18 UIViewControllerTransition.zoom spring kinematics:
  // Push: response ≈ 0.36s, dampingFraction ≈ 0.84 (~0.77% subtle breathe-in settle)
  // Pop:  response ≈ 0.30s, dampingFraction ≈ 0.94 (crisp magnetic snap, zero wobble)
  static final Curve _pushSpring = _AppleSpringCurve(
    mass: 1.0,
    stiffness: 305.0,
    damping: 29.34,
    durationSec: 0.46,
  );

  static final Curve _popSpring = _AppleSpringCurve(
    mass: 1.0,
    stiffness: 438.6,
    damping: 39.37,
    durationSec: 0.36,
  );

  // Cached per-route page widget wrapped in a single RepaintBoundary so the
  // GPU composites one crisp layer at locked 120Hz without re-rasterizing blur.
  Widget? _cachedPage;
  bool _claimedRegistry = false;
  // Tracks the exact animation value where an interactive edge-swipe released so
  // the post-release spring continues seamlessly with zero visual jump.
  double? _gestureReleaseRawT;
  bool _gestureReleasePopping = false;

  PosterExpandRoute({
    required this.builder,
    required this.initialSourceRect,
    this.sourceRectResolver,
    this.sourceBorderRadius = 14.0,
    this.sourceCardId,
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

  void _claimSourceCard() {
    final id = sourceCardId;
    if (id != null && id.isNotEmpty) {
      _claimedRegistry = true;
      PosterExpandRegistry.activeCardId.value = id;
    }
  }

  void _releaseSourceCard() {
    if (_claimedRegistry && PosterExpandRegistry.activeCardId.value == sourceCardId) {
      PosterExpandRegistry.activeCardId.value = null;
    }
    _claimedRegistry = false;
  }

  @override
  void install() {
    super.install();
    _claimSourceCard();
  }

  @override
  void dispose() {
    _releaseSourceCard();
    super.dispose();
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
  Duration get transitionDuration => const Duration(milliseconds: 460);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 360);

  void _setSwipeProgress(double value) {
    _gestureReleaseRawT = null;
    controller?.value = value.clamp(0.0, 1.0);
  }

  void _endSwipeGesture({required double velocity}) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;
    final shouldPop = velocity > 380.0 || ctrl.value < 0.72;
    _gestureReleaseRawT = ctrl.value.clamp(0.0, 1.0);
    _gestureReleasePopping = shouldPop;
    if (shouldPop) {
      nav.pop();
    } else {
      ctrl.forward();
    }
    nav.didStopUserGesture();
  }

  void _cancelSwipeGesture() {
    final ctrl = controller;
    if (ctrl != null) {
      _gestureReleaseRawT = ctrl.value.clamp(0.0, 1.0);
      _gestureReleasePopping = false;
      ctrl.forward();
    }
    navigator?.didStopUserGesture();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _cachedPage ??= RepaintBoundary(
      child: _PosterExpandSwipeBackWrapper<T>(
        route: this,
        child: builder(context),
      ),
    );
  }

  ({Rect rect, bool hasLiveAnchor}) _resolveLiveTargetRect(Size screen) {
    final live = sourceRectResolver?.call();
    if (live != null &&
        live.width >= 8 &&
        live.height >= 8 &&
        live.overlaps((Offset.zero & screen).inflate(80))) {
      return (rect: live, hasLiveAnchor: true);
    }
    if (initialSourceRect.width >= 8 && initialSourceRect.height >= 8) {
      return (rect: initialSourceRect, hasLiveAnchor: true);
    }
    final w = screen.width * 0.28;
    final h = w * 1.48;
    return (
      rect: Rect.fromCenter(
        center: Offset(screen.width * 0.5, screen.height * 0.5),
        width: w,
        height: h,
      ),
      hasLiveAnchor: false,
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

        // Settled fully open: paint directly with zero clipping or transform overhead.
        if (animation.status == AnimationStatus.completed && rawT >= 0.999) {
          _gestureReleaseRawT = null;
          return pageChild!;
        }
        if (animation.status == AnimationStatus.dismissed) {
          _gestureReleaseRawT = null;
        }

        final isGesture = navigator?.userGestureInProgress ?? false;
        final isReversing = animation.status == AnimationStatus.reverse;

        // When interactively swiping, track 1:1 with finger; on release hand off
        // continuously from the exact release point; otherwise run Apple spring physics.
        final double springT;
        final releaseT = _gestureReleaseRawT;
        if (isGesture) {
          springT = rawT;
        } else if (releaseT != null && _gestureReleasePopping && isReversing) {
          final span = releaseT.clamp(0.001, 1.0);
          final u = ((releaseT - rawT) / span).clamp(0.0, 1.0);
          springT = releaseT * (1.0 - _popSpring.transform(u));
        } else if (releaseT != null && !_gestureReleasePopping && !isReversing) {
          final span = (1.0 - releaseT).clamp(0.001, 1.0);
          final u = ((rawT - releaseT) / span).clamp(0.0, 1.0);
          springT = releaseT + (1.0 - releaseT) * _popSpring.transform(u);
        } else if (isReversing) {
          // Run pop spring cleanly from 1 -> 0 so collapse starts briskly and
          // lands with critically-damped precision directly on targetRect.
          springT = 1.0 - _popSpring.transform(1.0 - rawT);
        } else {
          springT = _pushSpring.transform(rawT);
        }

        final target = _resolveLiveTargetRect(screen);
        final sourceRect = target.rect;

        // Lerp rect using real spring progress (allows subtle ~0.8% micro-overshoot
        // on push while safely clamping dimensions >= 1.0).
        final lerpedLeft = lerpDouble(sourceRect.left, fullRect.left, springT)!;
        final lerpedTop = lerpDouble(sourceRect.top, fullRect.top, springT)!;
        final lerpedRight =
            lerpDouble(sourceRect.right, fullRect.right, springT)!;
        final lerpedBottom =
            lerpDouble(sourceRect.bottom, fullRect.bottom, springT)!;
        final currentRect = Rect.fromLTRB(
          lerpedLeft,
          lerpedTop,
          lerpedRight > lerpedLeft + 1 ? lerpedRight : lerpedLeft + 1,
          lerpedBottom > lerpedTop + 1 ? lerpedBottom : lerpedTop + 1,
        );

        final clampedT = springT.clamp(0.0, 1.0);
        // Smooth corner morph: source card radius -> crisp 0 when full-screen
        // (during interactive swipe, subtly lifts corners up to 28pt like iOS 18).
        final currentRadius = isGesture
            ? (lerpDouble(sourceBorderRadius, 28.0, (1.0 - rawT).clamp(0.0, 1.0)) ??
                    sourceBorderRadius) *
                (1.0 - (rawT > 0.96 ? (rawT - 0.96) / 0.04 : 0.0))
            : (lerpDouble(sourceBorderRadius, 0.0, Curves.easeOutCubic.transform(clampedT)) ??
                0.0);

        final backdropDim =
            (Curves.easeOut.transform(clampedT) * 0.40).clamp(0.0, 0.40);

        // Single opaque hardware-clipped layer — never allocate an offscreen
        // Opacity saveLayer when a live anchor exists (eliminates all ghosting).
        Widget flyingCard = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(currentRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: 0.34 * (1.0 - clampedT * 0.65),
                ),
                blurRadius: 26 * (1.0 - clampedT * 0.70),
                offset: Offset(0, 8 * (1.0 - clampedT * 0.70)),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(currentRadius),
            child: FittedBox(
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: screen.width,
                height: screen.height,
                child: pageChild,
              ),
            ),
          ),
        );

        if (!target.hasLiveAnchor) {
          final fallbackOpacity = (rawT / 0.14).clamp(0.0, 1.0);
          flyingCard = Opacity(opacity: fallbackOpacity, child: flyingCard);
        }

        return Stack(
          key: const Key('poster-expand-transition-stage'),
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: backdropDim),
              ),
            ),
            Positioned.fromRect(
              rect: currentRect,
              child: flyingCard,
            ),
          ],
        );
      },
    );
  }
}

/// Interactive left-edge horizontal swipe-back gesture detector so iOS users
/// can swipe back from the screen edge and watch [DetailScreen] detach and
/// implode smoothly back into the originating poster card in real time.
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

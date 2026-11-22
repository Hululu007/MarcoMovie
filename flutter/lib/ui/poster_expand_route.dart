import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'poster_image.dart';

/// Tracks the currently expanding/collapsing poster card ID and its live linear
/// transition progress (`0.0` at rest -> `1.0` fully open) so:
/// - The originating poster card on Home / Discovery / Search / Library hides
///   cleanly without collapsing its layout [RenderBox], eliminating duplicate
///   stationary ghosting behind the flying container.
/// - Full-bleed Home Hero chrome (floating top header, title, CTA, dots) can
///   cross-fade in exact 1:1 linear lockstep with the route animation.
class PosterExpandRegistry {
  PosterExpandRegistry._();

  static final ValueNotifier<String?> activeCardId =
      ValueNotifier<String?>(null);
  static final ValueNotifier<double> activeProgress =
      ValueNotifier<double>(0.0);
  static final List<String> _cardStack = <String>[];

  static void claim(String id) {
    if (id.isEmpty) return;
    _cardStack.add(id);
    activeCardId.value = id;
  }

  static void release(String id) {
    if (id.isEmpty) return;
    final idx = _cardStack.lastIndexOf(id);
    if (idx >= 0) {
      _cardStack.removeAt(idx);
    }
    activeCardId.value = _cardStack.isEmpty ? null : _cardStack.last;
    if (_cardStack.isEmpty) {
      activeProgress.value = 0.0;
    }
  }
}

/// Wraps a clickable poster card so it hides cleanly without collapsing layout
/// space strictly while its [PosterExpandRoute] is actively flying away from
/// rest (`activeProgress > 0.035`), keeping the real card painted underneath at
/// frame 0 of push and during the final landing frames of pop so there is NEVER
/// a 1-frame white hole flash or jump.
class PosterExpandSourceCard extends StatelessWidget {
  final String cardId;
  final Widget child;

  const PosterExpandSourceCard({
    super.key,
    required this.cardId,
    required this.child,
  });

  static final Listenable _registryListenable = Listenable.merge([
    PosterExpandRegistry.activeCardId,
    PosterExpandRegistry.activeProgress,
  ]);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _registryListenable,
      child: child,
      builder: (context, cardChild) {
        final activeId = PosterExpandRegistry.activeCardId.value;
        final progress = PosterExpandRegistry.activeProgress.value;
        final hidden =
            activeId != null && activeId == cardId && progress > 0.035;
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

/// Smooth, strictly monotonic linear-fluid shared-container route for every
/// series/show card AND full-bleed Home Hero on iOS / iPadOS:
///
/// - **Unified Linear Kinematics**: Uses a single zero-overshoot, symmetric
///   linear-fluid curve (`Cubic(0.28, 0.16, 0.24, 1.0)`) driving rect, corner
///   radius, backdrop dim, shadow, and poster-to-detail cross-morph off one
///   shared progress scalar `p` — eliminating spring overshoot, mid-flight
///   speed cliffs, and double-eased visual mismatches.
/// - **Zero Ghosting & Zero Hard-Cut Swap**: Hides the originating card via
///   [PosterExpandRegistry] and paints a 100% opaque shared poster base inside
///   the morphing container with the cached [DetailScreen] dissolving cleanly
///   over it, so composite alpha is always `1.0` and frame `0` matches the
///   tapped card pixel-for-pixel on both open and return.
/// - **Seamless Full-Bleed Hero Mode (`isFullBleedHero`)**: Eliminates the
///   horizontal middle split ("中间割裂感") when opening/returning from the
///   Home immersive hero by preserving `0pt` edge-to-edge corners, removing
///   floating card shadows, and dynamically feathering the bottom edge into
///   Home content while smoothly aligning the shared HD poster.
/// - **Continuous Interactive Edge Swipe-Back**: Left-edge swipe tracks the
///   finger 1:1 and hands off on release from the exact position and corner
///   radius with zero 1-frame jump.
class PosterExpandRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Rect initialSourceRect;
  final Rect? Function()? sourceRectResolver;
  final double sourceBorderRadius;
  final String? sourceCardId;
  final String posterUrl;
  final String title;
  final String year;
  final bool isFullBleedHero;
  final bool strictHighResPoster;
  final bool forBackdrop;
  final Alignment posterAlignment;
  final Color ambientColor;

  /// Critically smooth, zero-overshoot continuous curve keeping an even,
  /// linear-feeling glide across the middle of the flight with soft cushions
  /// at takeoff and landing.
  static const Curve _linearFluidCurve = Cubic(0.28, 0.16, 0.24, 1.0);

  @visibleForTesting
  static double evaluateTransitionProgress(
    double rawT, {
    bool reversing = false,
  }) {
    final t = rawT.clamp(0.0, 1.0);
    if (reversing) {
      return (1.0 - _linearFluidCurve.transform(1.0 - t)).clamp(0.0, 1.0);
    }
    return _linearFluidCurve.transform(t).clamp(0.0, 1.0);
  }

  // Cached per-route destination page wrapped in a single keyed RepaintBoundary
  // so Flutter reparents DetailScreen's Element/State with zero dispose/re-init
  // between settled full-screen and active transition frames, compositing one
  // crisp GPU layer at 120Hz without re-rasterizing blur.
  final GlobalKey _pageBoundaryKey = GlobalKey();
  final GlobalKey _sharedPosterKey = GlobalKey();
  Widget? _cachedPage;
  Widget? _cachedSharedPoster;
  bool _claimedRegistry = false;
  bool _listenerAttached = false;

  // Tracks exact release state after an interactive left-edge swipe so post-
  // release continuation starts from the exact finger position and radius with
  // zero visual jump.
  double? _gestureReleaseRawT;
  double _gestureReleaseRadiusOffset = 0.0;
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
    this.isFullBleedHero = false,
    this.strictHighResPoster = false,
    this.forBackdrop = false,
    this.posterAlignment = Alignment.center,
    this.ambientColor = const Color(0xFF0E1016),
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
      PosterExpandRegistry.claim(id);
    }
  }

  void _releaseSourceCard() {
    final id = sourceCardId;
    if (_claimedRegistry && id != null && id.isNotEmpty) {
      PosterExpandRegistry.release(id);
    }
    _claimedRegistry = false;
  }

  void _handleAnimationTick() {
    final anim = animation;
    if (anim == null || !_claimedRegistry) return;
    if (PosterExpandRegistry.activeCardId.value != sourceCardId) return;
    final p = _computeProgress(
      rawT: anim.value.clamp(0.0, 1.0),
      status: anim.status,
      isGesture: navigator?.userGestureInProgress ?? false,
    );
    if ((PosterExpandRegistry.activeProgress.value - p).abs() > 0.0005) {
      PosterExpandRegistry.activeProgress.value = p;
    }
  }

  @override
  void install() {
    super.install();
    _claimSourceCard();
    if (!_listenerAttached && animation != null) {
      _listenerAttached = true;
      animation!.addListener(_handleAnimationTick);
    }
  }

  @override
  void dispose() {
    if (_listenerAttached && animation != null) {
      animation!.removeListener(_handleAnimationTick);
      _listenerAttached = false;
    }
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
  Duration get transitionDuration => const Duration(milliseconds: 340);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 310);

  double _gestureRadiusBumpFor(double p, {required bool fullBleed}) {
    final lift = fullBleed ? 24.0 : 12.0;
    return lift * math.sin(math.pi * p.clamp(0.0, 1.0));
  }

  void _setSwipeProgress(double value) {
    _gestureReleaseRawT = null;
    _gestureReleaseRadiusOffset = 0.0;
    controller?.value = value.clamp(0.0, 1.0);
  }

  void _endSwipeGesture({required double velocity}) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;
    final releaseVal = ctrl.value.clamp(0.0, 1.0);
    final shouldPop = velocity > 380.0 || releaseVal < 0.72;
    _gestureReleaseRawT = releaseVal;
    _gestureReleaseRadiusOffset = _gestureRadiusBumpFor(
      releaseVal,
      fullBleed: isFullBleedHero,
    );
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
      final releaseVal = ctrl.value.clamp(0.0, 1.0);
      _gestureReleaseRawT = releaseVal;
      _gestureReleaseRadiusOffset = _gestureRadiusBumpFor(
        releaseVal,
        fullBleed: isFullBleedHero,
      );
      _gestureReleasePopping = false;
      ctrl.forward();
    }
    navigator?.didStopUserGesture();
  }

  double _computeProgress({
    required double rawT,
    required AnimationStatus status,
    required bool isGesture,
  }) {
    if (isGesture) return rawT;
    final isReversing = status == AnimationStatus.reverse;
    final releaseT = _gestureReleaseRawT;
    if (releaseT != null && _gestureReleasePopping && isReversing) {
      final span = releaseT.clamp(0.001, 1.0);
      final u = ((releaseT - rawT) / span).clamp(0.0, 1.0);
      return (releaseT * (1.0 - _linearFluidCurve.transform(u)))
          .clamp(0.0, 1.0);
    }
    if (releaseT != null && !_gestureReleasePopping && !isReversing) {
      final span = (1.0 - releaseT).clamp(0.001, 1.0);
      final u = ((rawT - releaseT) / span).clamp(0.0, 1.0);
      return (releaseT + (1.0 - releaseT) * _linearFluidCurve.transform(u))
          .clamp(0.0, 1.0);
    }
    return evaluateTransitionProgress(rawT, reversing: isReversing);
  }

  double _computeGestureRadiusOffset({
    required double rawT,
    required double p,
    required AnimationStatus status,
    required bool isGesture,
    required bool fullBleed,
  }) {
    if (isGesture) {
      return _gestureRadiusBumpFor(p, fullBleed: fullBleed);
    }
    final releaseT = _gestureReleaseRawT;
    if (releaseT == null || _gestureReleaseRadiusOffset <= 0.01) {
      return 0.0;
    }
    final isReversing = status == AnimationStatus.reverse;
    if (_gestureReleasePopping && isReversing) {
      final span = releaseT.clamp(0.001, 1.0);
      final u = ((releaseT - rawT) / span).clamp(0.0, 1.0);
      return _gestureReleaseRadiusOffset *
          (1.0 - _linearFluidCurve.transform(u));
    }
    if (!_gestureReleasePopping && !isReversing) {
      final span = (1.0 - releaseT).clamp(0.001, 1.0);
      final u = ((rawT - releaseT) / span).clamp(0.0, 1.0);
      return _gestureReleaseRadiusOffset *
          (1.0 - _linearFluidCurve.transform(u));
    }
    return 0.0;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _cachedPage ??= RepaintBoundary(
      key: _pageBoundaryKey,
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
    if (initialSourceRect.width >= 8 &&
        initialSourceRect.height >= 8 &&
        initialSourceRect.overlaps((Offset.zero & screen).inflate(80))) {
      // Clamp fallback rect inside the current viewport so live fold/unfold
      // (e.g. iPhone Duo 466×678 ↔ 669×951) never flies back off-screen.
      final clampedW = initialSourceRect.width.clamp(8.0, screen.width).toDouble();
      final clampedH = initialSourceRect.height.clamp(8.0, screen.height).toDouble();
      final clampedLeft = initialSourceRect.left
          .clamp(0.0, math.max<double>(0.0, screen.width - clampedW))
          .toDouble();
      final clampedTop = initialSourceRect.top
          .clamp(0.0, math.max<double>(0.0, screen.height - clampedH))
          .toDouble();
      return (
        rect: Rect.fromLTWH(clampedLeft, clampedTop, clampedW, clampedH),
        hasLiveAnchor: true,
      );
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

  bool get _hasSharedPoster =>
      posterUrl.trim().isNotEmpty || title.trim().isNotEmpty;

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
          _gestureReleaseRadiusOffset = 0.0;
          return pageChild!;
        }
        if (animation.status == AnimationStatus.dismissed) {
          _gestureReleaseRawT = null;
          _gestureReleaseRadiusOffset = 0.0;
        }

        final isGesture = navigator?.userGestureInProgress ?? false;
        final p = _computeProgress(
          rawT: rawT,
          status: animation.status,
          isGesture: isGesture,
        );

        final target = _resolveLiveTargetRect(screen);
        final sourceRect = target.rect;
        final effectiveFullBleedHero = isFullBleedHero ||
            (sourceBorderRadius <= 0.5 &&
                sourceRect.width >= screen.width * 0.94 &&
                sourceRect.top <= 4.0);

        final gestureRadiusOffset = _computeGestureRadiusOffset(
          rawT: rawT,
          p: p,
          status: animation.status,
          isGesture: isGesture,
          fullBleed: effectiveFullBleedHero,
        );

        final lerpedLeft = lerpDouble(sourceRect.left, fullRect.left, p)!;
        final lerpedTop = lerpDouble(sourceRect.top, fullRect.top, p)!;
        final lerpedRight = lerpDouble(sourceRect.right, fullRect.right, p)!;
        final lerpedBottom = lerpDouble(sourceRect.bottom, fullRect.bottom, p)!;
        final currentRect = Rect.fromLTRB(
          lerpedLeft,
          lerpedTop,
          lerpedRight > lerpedLeft + 1 ? lerpedRight : lerpedLeft + 1,
          lerpedBottom > lerpedTop + 1 ? lerpedBottom : lerpedTop + 1,
        );

        final baseRadius = effectiveFullBleedHero
            ? 0.0
            : (lerpDouble(sourceBorderRadius, 0.0, p) ?? 0.0);
        final currentRadius =
            (baseRadius + gestureRadiusOffset).clamp(0.0, 32.0);

        // Linear backdrop dimming strictly proportional to p (zero double-easing).
        final backdropDim =
            ((effectiveFullBleedHero ? 0.24 : 0.36) * p).clamp(0.0, 0.36);

        final isReversing = animation.status == AnimationStatus.reverse;
        if (effectiveFullBleedHero) {
          return _buildFullBleedHeroStage(
            screen: screen,
            currentRect: currentRect,
            currentRadius: currentRadius,
            gestureRadiusOffset: gestureRadiusOffset,
            backdropDim: backdropDim,
            p: p,
            rawT: rawT,
            hasLiveAnchor: target.hasLiveAnchor,
            isReversing: isReversing,
            pageChild: pageChild!,
          );
        }

        return _buildPosterCardStage(
          screen: screen,
          currentRect: currentRect,
          currentRadius: currentRadius,
          backdropDim: backdropDim,
          p: p,
          rawT: rawT,
          hasLiveAnchor: target.hasLiveAnchor,
          isReversing: isReversing,
          pageChild: pageChild!,
        );
      },
    );
  }

  Widget _sharedPosterLayer() {
    return _cachedSharedPoster ??= RepaintBoundary(
      key: _sharedPosterKey,
      child: PosterImage(
        url: posterUrl,
        title: title,
        year: year,
        highRes: true,
        strictHighRes: strictHighResPoster,
        forBackdrop: forBackdrop,
        fadeIn: false,
        fit: BoxFit.cover,
        alignment: posterAlignment,
        placeholder: ColoredBox(color: ambientColor),
      ),
    );
  }

  /// Seamless full-bleed Hero <-> DetailScreen transition:
  /// - Zero white alpha cutout (`ShaderMask`) and zero vertical alignment jump
  ///   so pushing from and popping back to Home never flashes white or jitters.
  /// - Preserves the exact poster ambient color gradient from the title zone
  ///   downward while [DetailScreen] dissolves cleanly over the shared HD poster.
  Widget _buildFullBleedHeroStage({
    required Size screen,
    required Rect currentRect,
    required double currentRadius,
    required double gestureRadiusOffset,
    required double backdropDim,
    required double p,
    required double rawT,
    required bool hasLiveAnchor,
    required bool isReversing,
    required Widget pageChild,
  }) {
    final detailOpacity =
        _hasSharedPoster ? ((p - 0.08) / 0.46).clamp(0.0, 1.0) : 1.0;

    final Widget detailLayer = SizedBox(
      width: screen.width,
      height: screen.height,
      child: pageChild,
    );

    final Widget content = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: ambientColor),
        if (_hasSharedPoster)
          Positioned.fill(
            child: _sharedPosterLayer(),
          ),
        // Match the Home Hero's smooth ambient-color fade below the title zone
        // while fading out as DetailScreen's own ambient surface takes over.
        if (detailOpacity < 0.98)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: currentRect.height * 0.48,
            child: IgnorePointer(
              child: Opacity(
                opacity: (1.0 - detailOpacity).clamp(0.0, 1.0),
                child: DecoratedBox(
                  key: const Key('poster-expand-hero-ambient-blend'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        ambientColor.withValues(alpha: 0.0),
                        ambientColor.withValues(alpha: 0.58),
                        ambientColor.withValues(alpha: 0.92),
                        ambientColor,
                      ],
                      stops: const [0.0, 0.36, 0.72, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),
        FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(detailOpacity),
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: screen.width,
            maxWidth: screen.width,
            minHeight: screen.height,
            maxHeight: screen.height,
            child: detailLayer,
          ),
        ),
      ],
    );

    Widget stageCard = currentRadius > 0.25
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(currentRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.26 * (1.0 - p)),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(currentRadius),
              child: content,
            ),
          )
        : ClipRect(child: content);

    final double edgeOpacity = !hasLiveAnchor
        ? (rawT / 0.16).clamp(0.0, 1.0)
        : (isReversing && p < 0.04 ? (p / 0.04).clamp(0.0, 1.0) : 1.0);
    if (edgeOpacity < 0.999) {
      stageCard = Opacity(opacity: edgeOpacity, child: stageCard);
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
          child: stageCard,
        ),
      ],
    );
  }

  /// Linear zero-ghosting, zero-flash card-to-screen container morph for every
  /// poster card across Home, Discovery, Search, Continue Watching, and Library.
  Widget _buildPosterCardStage({
    required Size screen,
    required Rect currentRect,
    required double currentRadius,
    required double backdropDim,
    required double p,
    required double rawT,
    required bool hasLiveAnchor,
    required bool isReversing,
    required Widget pageChild,
  }) {
    final detailOpacity =
        _hasSharedPoster ? ((p - 0.06) / 0.42).clamp(0.0, 1.0) : 1.0;

    final Widget scaledDetail = FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: screen.width,
        height: screen.height,
        child: pageChild,
      ),
    );

    final Widget innerContent = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: ambientColor),
        if (_hasSharedPoster)
          Positioned.fill(
            child: _sharedPosterLayer(),
          ),
        FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(detailOpacity),
          child: scaledDetail,
        ),
      ],
    );

    Widget flyingCard = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(currentRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28 * (1.0 - p)),
            blurRadius: 22.0 * (1.0 - p),
            offset: Offset(0, 6.0 * (1.0 - p)),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(currentRadius),
        child: innerContent,
      ),
    );

    // During the final landing frames (`p < 0.04` on reverse), the originating
    // `PosterExpandSourceCard` is already visible pixel-for-pixel underneath,
    // so gently dissolving `flyingCard` into it eliminates any 1-frame flash or
    // aspect-ratio snap on return.
    final double edgeOpacity = !hasLiveAnchor
        ? (rawT / 0.16).clamp(0.0, 1.0)
        : (isReversing && p < 0.04 ? (p / 0.04).clamp(0.0, 1.0) : 1.0);
    if (edgeOpacity < 0.999) {
      flyingCard = Opacity(opacity: edgeOpacity, child: flyingCard);
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
  }
}

/// Interactive left-edge horizontal swipe-back gesture detector so iOS users
/// can swipe back from the screen edge and watch [DetailScreen] detach and
/// glide smoothly back into the originating poster card in real time.
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

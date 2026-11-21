import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'poster_image.dart';

/// Plays the vintage-camera-flash -> 4:3 Marco Movie branded postcard ->
/// parabolic flight into the Dynamic Island -> Dynamic Island elastic capsule
/// feedback animation when a user adds a title to Favorites.
class FavoritePostcardFlightOverlay {
  FavoritePostcardFlightOverlay._();

  static OverlayEntry? _activeEntry;

  static Future<void> show(
    BuildContext context, {
    required String title,
    String posterUrl = '',
    String year = '',
    Uint8List? cachedBytes,
    Rect? originRect,
  }) async {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _activeEntry?.remove();
    _activeEntry = null;

    final bytes = cachedBytes ??
        PosterLoader.peekMemory(posterUrl, title: title, year: year);

    final islandMeta =
        await IosLiquidGlassBridge.triggerFavoriteDynamicIslandFeedback(
      'shutter',
    );
    if (!context.mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _FavoritePostcardAnimationWidget(
        title: title,
        posterUrl: posterUrl,
        year: year,
        cachedBytes: bytes,
        originRect: originRect,
        islandMeta: islandMeta,
        onFinished: () {
          if (_activeEntry == entry) {
            _activeEntry = null;
          }
          entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
    return completer.future;
  }
}

class _FavoritePostcardAnimationWidget extends StatefulWidget {
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;
  final Rect? originRect;
  final Map<String, dynamic>? islandMeta;
  final VoidCallback onFinished;

  const _FavoritePostcardAnimationWidget({
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
    required this.originRect,
    required this.islandMeta,
    required this.onFinished,
  });

  @override
  State<_FavoritePostcardAnimationWidget> createState() =>
      _FavoritePostcardAnimationWidgetState();
}

class _FavoritePostcardAnimationWidgetState
    extends State<_FavoritePostcardAnimationWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _arrivalTriggered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2350),
    );
    _controller.addListener(_onTick);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onFinished();
      }
    });
    HapticFeedback.mediumImpact();
    _controller.forward();
  }

  void _onTick() {
    // Trigger arrival haptic right as the postcard snaps into the Dynamic Island.
    if (!_arrivalTriggered && _controller.value >= 0.45) {
      _arrivalTriggered = true;
      HapticFeedback.heavyImpact();
      IosLiquidGlassBridge.triggerFavoriteDynamicIslandFeedback('arrive');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  Rect _resolveIslandRect(Size screen, EdgeInsets safePadding) {
    final meta = widget.islandMeta;
    if (meta != null && meta['hasDynamicIsland'] == true) {
      final w = (meta['islandWidth'] as num?)?.toDouble() ?? 126.0;
      final h = (meta['islandHeight'] as num?)?.toDouble() ?? 37.0;
      final y = (meta['islandTop'] as num?)?.toDouble() ?? 11.0;
      final x = (meta['islandX'] as num?)?.toDouble() ?? ((screen.width - w) / 2);
      return Rect.fromLTWH(x, y, w, h);
    }
    const w = 126.0;
    const h = 36.0;
    final top = math.max(10.0, safePadding.top > 24 ? 11.0 : safePadding.top + 6.0);
    return Rect.fromLTWH((screen.width - w) / 2, top, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final islandRect = _resolveIslandRect(screen, safe);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;

            // Phase 1 (0.00 -> 0.11): Vintage camera shutter flash & viewfinder
            final flashOpacity = reducedMotion
                ? 0.0
                : (t < 0.035
                    ? Curves.easeOut.transform(t / 0.035) * 0.88
                    : (t < 0.12
                        ? (1.0 - Curves.easeInCubic.transform((t - 0.035) / 0.085)) *
                            0.88
                        : 0.0));

            // Phase 2 (0.05 -> 0.29): 4:3 Branded Postcard develops center-stage
            // Phase 3 (0.29 -> 0.47): Parabolic flight with 3D perspective into Dynamic Island
            final showPostcard = !reducedMotion && t >= 0.04 && t <= 0.48;
            double cardOpacity = 0.0;
            double cardScale = 1.0;
            double cardRotateZ = 0.0;
            double cardTiltX = 0.0;
            Offset cardCenter = Offset(screen.width / 2, screen.height * 0.46);
            double developWash = 0.0;

            if (showPostcard) {
              if (t < 0.14) {
                final p = Curves.easeOutBack.transform(((t - 0.04) / 0.10).clamp(0.0, 1.0));
                cardOpacity = ((t - 0.04) / 0.06).clamp(0.0, 1.0);
                cardScale = 0.78 + 0.24 * p;
                cardRotateZ = -0.06 * (1.0 - p) - 0.025;
                developWash = (1.0 - p).clamp(0.0, 1.0) * 0.65;
              } else if (t < 0.29) {
                // Hold & gentle retro sway so user clearly sees the 4:3 postcard & Marco stamp
                final p = (t - 0.14) / 0.15;
                cardOpacity = 1.0;
                cardScale = 1.02 - 0.02 * math.sin(p * math.pi);
                cardRotateZ = -0.025 + 0.04 * p;
              } else {
                // Fly along an elevated quadratic Bezier curve into Dynamic Island
                final p = Curves.easeInOutCubic
                    .transform(((t - 0.29) / 0.18).clamp(0.0, 1.0));
                final p0 = Offset(screen.width / 2, screen.height * 0.46);
                final p2 = islandRect.center;
                final p1 = Offset(
                  screen.width * 0.68,
                  math.min(p0.dy, p2.dy) + (p0.dy - p2.dy) * 0.28,
                );
                final inv = 1.0 - p;
                cardCenter = Offset(
                  inv * inv * p0.dx + 2 * inv * p * p1.dx + p * p * p2.dx,
                  inv * inv * p0.dy + 2 * inv * p * p1.dy + p * p * p2.dy,
                );
                cardScale = 1.0 * (1.0 - p) + 0.16 * p;
                cardRotateZ = 0.015 * (1.0 - p) + 0.22 * p;
                cardTiltX = 0.45 * math.sin(p * math.pi);
                cardOpacity = p > 0.82
                    ? (1.0 - (p - 0.82) / 0.18).clamp(0.0, 1.0)
                    : 1.0;
              }
            }

            // Phase 4 (0.44 -> 1.00): Dynamic Island elastic expansion + feedback
            final showIslandFeedback = reducedMotion
                ? (t >= 0.05 && t <= 0.92)
                : (t >= 0.44 && t <= 0.98);
            double islandExpand = 0.0;
            if (showIslandFeedback) {
              if (reducedMotion) {
                islandExpand = 1.0;
              } else if (t < 0.56) {
                final p = ((t - 0.44) / 0.12).clamp(0.0, 1.0);
                islandExpand = Curves.easeOutBack.transform(p);
              } else if (t < 0.84) {
                islandExpand = 1.0;
              } else {
                final p = ((t - 0.84) / 0.14).clamp(0.0, 1.0);
                islandExpand = 1.0 - Curves.easeInCubic.transform(p);
              }
            }

            final cardWidth = math.min(268.0, screen.width * 0.74);
            // Strict 4:3 postcard aspect ratio
            final cardHeight = cardWidth * 3 / 4;

            return Stack(
              fit: StackFit.expand,
              children: [
                // Subtle cinema backdrop dim during postcard reveal
                if (showPostcard)
                  ColoredBox(
                    color: Colors.black.withValues(
                      alpha: 0.28 * cardOpacity * (t < 0.34 ? 1.0 : 0.35),
                    ),
                  ),

                // Retro camera flash + golden viewfinder brackets
                if (flashOpacity > 0.005)
                  _RetroCameraFlashLayer(opacity: flashOpacity),

                // 4:3 Branded Postcard
                if (showPostcard)
                  Positioned(
                    left: cardCenter.dx - cardWidth / 2,
                    top: cardCenter.dy - cardHeight / 2,
                    width: cardWidth,
                    height: cardHeight,
                    child: Opacity(
                      opacity: cardOpacity.clamp(0.0, 1.0),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0014)
                          ..rotateX(cardTiltX)
                          ..rotateZ(cardRotateZ)
                          ..scaleByDouble(cardScale, cardScale, 1.0, 1.0),
                        child: _BrandedPostcardCard(
                          key: const Key('favorite-postcard-card'),
                          title: widget.title,
                          posterUrl: widget.posterUrl,
                          year: widget.year,
                          cachedBytes: widget.cachedBytes,
                          developWash: developWash,
                        ),
                      ),
                    ),
                  ),

                // Dynamic Island elastic feedback pill
                if (showIslandFeedback)
                  _DynamicIslandFeedbackPill(
                    key: const Key('favorite-dynamic-island-feedback'),
                    islandRect: islandRect,
                    expandProgress: islandExpand,
                    title: widget.title,
                    posterUrl: widget.posterUrl,
                    year: widget.year,
                    cachedBytes: widget.cachedBytes,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RetroCameraFlashLayer extends StatelessWidget {
  final double opacity;
  const _RetroCameraFlashLayer({required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.05,
                colors: [
                  const Color(0xFFFFFDF4),
                  const Color(0xFFFFF4D6).withValues(alpha: 0.92),
                  const Color(0xFFFFD89B).withValues(alpha: 0.52),
                ],
              ),
            ),
          ),
          // Retro rangefinder focus corners
          Center(
            child: SizedBox(
              width: 240,
              height: 180,
              child: CustomPaint(painter: _ViewfinderCornersPainter()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewfinderCornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xCC1C1C1E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    const len = 18.0;
    // Top-left
    canvas.drawLine(Offset.zero, const Offset(len, 0), paint);
    canvas.drawLine(Offset.zero, const Offset(0, len), paint);
    // Top-right
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - len, 0), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), paint);
    // Bottom-left
    canvas.drawLine(Offset(0, size.height), Offset(len, size.height), paint);
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - len), paint);
    // Bottom-right
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - len, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - len),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BrandedPostcardCard extends StatelessWidget {
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;
  final double developWash;

  const _BrandedPostcardCard({
    super.key,
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
    required this.developWash,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStamp =
        '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';

    final placeholder = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B3242), Color(0xFF151822)],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film_fill,
        color: Colors.white38,
        size: 36,
      ),
    );

    final photo = cachedBytes != null
        ? Image.memory(
            cachedBytes!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : PosterImage(
            url: posterUrl,
            title: title,
            year: year,
            fit: BoxFit.cover,
            fadeIn: false,
            placeholder: placeholder,
          );

    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 9, 9, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFAF6EE),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFE7DEC9),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.36),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    photo,
                    // Subtle warm film grain / vignette sheen
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0x18FFD48A),
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.34),
                          ],
                        ),
                      ),
                    ),
                    // Brand logo stamp tag pinned to top-right corner
                    Positioned(
                      top: 7,
                      right: 7,
                      child: Transform.rotate(
                        angle: 0.07,
                        child: Container(
                          key: const Key('favorite-postcard-brand-stamp'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3.5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xE8141418),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xAAFFE4A3),
                              width: 0.85,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3.5),
                                child: Image.asset(
                                  'assets/logo_mark.png',
                                  width: 14,
                                  height: 14,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    CupertinoIcons.film,
                                    size: 12,
                                    color: Color(0xFFFFE4A3),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'MARCO',
                                style: TextStyle(
                                  color: Color(0xFFFFF1CC),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Vintage Polaroid develop wash
                    if (developWash > 0.01)
                      ColoredBox(
                        color: const Color(0xFFFFF9EA)
                            .withValues(alpha: developWash.clamp(0.0, 1.0)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            // Postcard footer caption & postmark date
            Row(
              children: [
                const Icon(
                  CupertinoIcons.heart_fill,
                  size: 12,
                  color: AppleColors.systemPink,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title.isNotEmpty ? title : '我的收藏',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF1F1D1A),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  dateStamp,
                  style: const TextStyle(
                    color: Color(0xFF8B8274),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DynamicIslandFeedbackPill extends StatelessWidget {
  final Rect islandRect;
  final double expandProgress;
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;

  const _DynamicIslandFeedbackPill({
    super.key,
    required this.islandRect,
    required this.expandProgress,
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final p = expandProgress.clamp(0.0, 1.15);
    final clamped = expandProgress.clamp(0.0, 1.0);
    final targetW = math.min(286.0, screen.width - 28.0);
    const targetH = 54.0;
    final currentW = islandRect.width + (targetW - islandRect.width) * p;
    final currentH = islandRect.height + (targetH - islandRect.height) * p;
    final left = (islandRect.center.dx - currentW / 2)
        .clamp(14.0, screen.width - currentW - 14.0);
    final top = islandRect.top;

    final thumbPlaceholder = Container(
      color: const Color(0xFF23252C),
      alignment: Alignment.center,
      child: const Icon(CupertinoIcons.film, color: Colors.white54, size: 14),
    );

    return Positioned(
      left: left,
      top: top,
      width: currentW.clamp(islandRect.width, screen.width - 20),
      height: currentH.clamp(islandRect.height, 68),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF000000),
          borderRadius: BorderRadius.circular(currentH / 2),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14 * clamped),
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45 * clamped),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Opacity(
          opacity: ((clamped - 0.15) / 0.85).clamp(0.0, 1.0),
          child: Row(
            children: [
              // Miniature 4:3 postcard thumbnail inside the Dynamic Island
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 36,
                  height: 27,
                  padding: const EdgeInsets.all(1.5),
                  color: const Color(0xFFFAF6EE),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: cachedBytes != null
                        ? Image.memory(
                            cachedBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : PosterImage(
                            url: posterUrl,
                            title: title,
                            year: year,
                            fit: BoxFit.cover,
                            fadeIn: false,
                            placeholder: thumbPlaceholder,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '已收藏明信片 · Marco',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      title.isNotEmpty ? title : '已加入我的片库',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppleColors.systemPink.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  CupertinoIcons.heart_fill,
                  size: 13.5,
                  color: AppleColors.systemPink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

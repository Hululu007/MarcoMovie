import 'package:flutter/cupertino.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_press_slide_menu.dart';
import 'poster_expand_route.dart';
import 'poster_image.dart';

/// Opens a history entry while keeping the poster-expand hero transition.
typedef IosHistoryOpenCallback = void Function(
  WatchHistoryEntry entry,
  BuildContext posterContext,
  double radius,
  String cardId,
);

/// Menu action ids shared by the native `UIMenu` and the Flutter fallback.
const String kIosHistoryMenuResume = 'resume';
const String kIosHistoryMenuDelete = 'delete';

/// `mm:ss` / `h:mm:ss` clock label for a millisecond position.
String iosHistoryFormatClock(int ms) {
  final total = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Short subtitle under each history poster, e.g. `第3集 · 看到 12:34`.
String iosHistoryCardSubtitle(WatchHistoryEntry h) {
  final episode = h.episode.trim();
  final ep = episode.isEmpty ? '第 ${h.index + 1} 集' : episode;
  if (h.complete) return '$ep · 已看完';
  if (h.position > 0) return '$ep · 看到 ${iosHistoryFormatClock(h.position)}';
  return ep;
}

/// iOS 片库「观看历史」poster wall: same grid rhythm as the favorites wall,
/// tap to continue, long-press for a (native on iOS 26+) delete menu.
class IosHistoryPosterWall extends StatelessWidget {
  final List<WatchHistoryEntry> entries;
  final String Function(WatchHistoryEntry entry) posterOf;
  final double maxCrossAxisExtent;
  final EdgeInsetsGeometry padding;
  final IosHistoryOpenCallback onOpen;
  final ValueChanged<WatchHistoryEntry> onDelete;
  final Widget Function()? placeholderBuilder;

  const IosHistoryPosterWall({
    super.key,
    required this.entries,
    required this.posterOf,
    required this.maxCrossAxisExtent,
    required this.onOpen,
    required this.onDelete,
    this.padding = EdgeInsets.zero,
    this.placeholderBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: const ValueKey('ios-history-poster-wall'),
      padding: padding,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.56,
      ),
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final h = entries[i];
        return IosHistoryPosterCard(
          key: ValueKey('lib_hist_${h.site}_${h.id}'),
          entry: h,
          posterUrl: posterOf(h),
          cardId: 'lib_hist_${h.site}_${h.id}_$i',
          onOpen: onOpen,
          onDelete: onDelete,
          placeholderBuilder: placeholderBuilder,
        );
      },
    );
  }
}

class IosHistoryPosterCard extends StatefulWidget {
  final WatchHistoryEntry entry;
  final String posterUrl;
  final String cardId;
  final IosHistoryOpenCallback onOpen;
  final ValueChanged<WatchHistoryEntry> onDelete;
  final Widget Function()? placeholderBuilder;

  const IosHistoryPosterCard({
    super.key,
    required this.entry,
    required this.posterUrl,
    required this.cardId,
    required this.onOpen,
    required this.onDelete,
    this.placeholderBuilder,
  });

  @override
  State<IosHistoryPosterCard> createState() => _IosHistoryPosterCardState();
}

class _IosHistoryPosterCardState extends State<IosHistoryPosterCard> {
  static const double _radius = 20.0;
  BuildContext? _posterCtx;
  bool _nativeMenuBusy = false;

  void _open() {
    final ctx = _posterCtx;
    widget.onOpen(
      widget.entry,
      (ctx != null && ctx.mounted) ? ctx : context,
      _radius,
      widget.cardId,
    );
  }

  void _handleAction(String? id) {
    if (!mounted || id == null) return;
    if (id == kIosHistoryMenuResume) {
      _open();
    } else if (id == kIosHistoryMenuDelete) {
      widget.onDelete(widget.entry);
    }
  }

  Rect _globalRect() {
    final ctx = _posterCtx;
    final render = ((ctx != null && ctx.mounted) ? ctx : context)
        .findRenderObject();
    if (render is RenderBox && render.attached && render.hasSize) {
      return render.localToGlobal(Offset.zero) & render.size;
    }
    return Rect.zero;
  }

  Future<void> _presentNativeMenu() async {
    if (_nativeMenuBusy) return;
    _nativeMenuBusy = true;
    HapticFeedback.mediumImpact();
    try {
      final selected = await IosLiquidGlassBridge.presentNativeContextMenu(
        anchorRect: _globalRect(),
        items: [
          IosNativeMenuItem(
            id: kIosHistoryMenuResume,
            title: '继续播放',
            subtitle: iosHistoryCardSubtitle(widget.entry),
            symbol: 'play.fill',
          ),
          const IosNativeMenuItem(
            id: kIosHistoryMenuDelete,
            title: '删除记录',
            symbol: 'trash',
            destructive: true,
            section: 1,
          ),
        ],
      );
      _handleAction(selected);
    } finally {
      _nativeMenuBusy = false;
    }
  }

  List<IosSlideMenuAction> _fallbackItems() => [
        IosSlideMenuAction(
          id: kIosHistoryMenuResume,
          title: '继续播放',
          subtitle: iosHistoryCardSubtitle(widget.entry),
          icon: CupertinoIcons.play_fill,
        ),
        const IosSlideMenuAction(
          id: kIosHistoryMenuDelete,
          title: '删除记录',
          icon: CupertinoIcons.trash,
          destructive: true,
          section: 1,
        ),
      ];

  Widget _placeholder(BuildContext context) {
    final builder = widget.placeholderBuilder;
    if (builder != null) return builder();
    final palette = ApplePalette.of(context);
    return ColoredBox(
      color: palette.isDark ? const Color(0xFF1C1C20) : const Color(0xFFE5E8F0),
      child: Center(
        child: Icon(CupertinoIcons.film, color: palette.labelTertiary, size: 26),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final h = widget.entry;
    final palette = ApplePalette.of(context);
    final fraction = h.complete ? 1.0 : h.progressFraction.clamp(0.0, 1.0);
    final showProgress = h.duration > 0 && fraction > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PosterExpandSourceCard(
            cardId: widget.cardId,
            child: Builder(
              builder: (ctx) {
                _posterCtx = ctx;
                return AppleSmoothClipCard(
                  borderRadius: _radius,
                  backgroundColor: const Color(0xFF1C1C20),
                  rimStrength: 0.86,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x36000000),
                      blurRadius: 12,
                      offset: Offset(0, 5),
                    ),
                  ],
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: widget.posterUrl,
                        title: h.title,
                        placeholder: _placeholder(context),
                      ),
                      if (showProgress)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(9, 18, 9, 9),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x00000000), Color(0x99000000)],
                              ),
                            ),
                            child: _PosterProgressBar(
                              key: const ValueKey('ios-history-progress'),
                              value: fraction,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          h.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.labelPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          iosHistoryCardSubtitle(h),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.labelSecondary, fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final card = RepaintBoundary(child: _buildCard(context));
    final label = '${widget.entry.title}，${iosHistoryCardSubtitle(widget.entry)}';
    if (IosLiquidGlassBridge.isAvailable) {
      return Semantics(
        button: true,
        label: label,
        hint: '轻点继续播放，长按显示更多操作',
        onTap: _open,
        onLongPress: _presentNativeMenu,
        customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
          const CustomSemanticsAction(label: '删除记录'): () =>
              widget.onDelete(widget.entry),
        },
        child: ApplePressableScale(
          pressedScale: 0.97,
          pressedOpacity: 0.92,
          onTap: _open,
          onLongPress: _presentNativeMenu,
          child: card,
        ),
      );
    }
    return IosPressSlideMenuAnchor(
      openOnTap: false,
      onTap: _open,
      itemsBuilder: _fallbackItems,
      onSelected: _handleAction,
      accessibilityLabel: label,
      accessibilityHint: '轻点继续播放，长按显示更多操作',
      menuKey: const ValueKey('ios-history-longpress-menu'),
      menuWidth: 224,
      minTouchWidth: 0,
      minTouchHeight: 0,
      preferredAnchor: Alignment.bottomCenter,
      child: SizedBox.expand(child: card),
    );
  }
}

/// Thin Apple TV–style progress capsule overlaid on the poster bottom.
class _PosterProgressBar extends StatelessWidget {
  final double value;
  const _PosterProgressBar({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 3.5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0x4DFFFFFF)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0),
              child: const ColoredBox(color: Color(0xF2FFFFFF)),
            ),
          ],
        ),
      ),
    );
  }
}

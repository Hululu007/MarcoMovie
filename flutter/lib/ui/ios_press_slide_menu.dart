import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show Colors, Divider, Material, MaterialType, ModalBarrier;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'motion/ios27_springs.dart';
import 'motion/motion_tokens.dart';

/// A single actionable row inside [IosPressSlideMenuAnchor].
class IosSlideMenuAction {
  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool destructive;
  final int section;
  final String? sectionTitle;

  const IosSlideMenuAction({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.selected = false,
    this.destructive = false,
    this.section = 0,
    this.sectionTitle,
  });
}

/// Unified iOS Flutter-fallback press-and-slide / tap-to-select glass menu.
///
/// Behavior contract:
/// - When [openOnTap] is `true` (e.g. collapsed Logo button), tapping opens the
///   menu; long-pressing ALSO opens the exact same menu and supports sliding a
///   finger directly onto any item and releasing to select.
/// - When [openOnTap] is `false` (e.g. expanded Dock tabs or top-right header
///   buttons), tapping triggers [onTap], while long-pressing opens the menu.
/// - Sliding off the menu (outside both the menu and the anchor) and releasing
///   cancels without invoking any action.
/// - Releasing on the anchor after long-press keeps the menu open so the user
///   can tap any row to select.
/// - Strictly guarantees at most ONE action fires per gesture sequence.
class IosPressSlideMenuAnchor extends StatefulWidget {
  final Widget child;
  final List<IosSlideMenuAction> Function() itemsBuilder;
  final ValueChanged<String> onSelected;
  final VoidCallback? onTap;
  final bool openOnTap;
  final bool enabled;
  final String? accessibilityLabel;
  final String? accessibilityHint;
  final Key? menuKey;
  final double menuWidth;
  final double minTouchWidth;
  final double minTouchHeight;
  final Alignment preferredAnchor;

  /// Scale applied while the finger is down. Dock tabs pass `1.0` so a
  /// long-press never makes the pressed tab float / pop (0.7.9 feedback).
  final double pressedScale;

  /// Optional opacity highlight while pressed (subtle press feedback).
  final double? pressedOpacity;

  const IosPressSlideMenuAnchor({
    super.key,
    required this.child,
    required this.itemsBuilder,
    required this.onSelected,
    this.onTap,
    this.openOnTap = false,
    this.enabled = true,
    this.accessibilityLabel,
    this.accessibilityHint,
    this.menuKey,
    this.menuWidth = 204,
    this.minTouchWidth = 44,
    this.minTouchHeight = 44,
    this.preferredAnchor = Alignment.topRight,
    this.pressedScale = 0.96,
    this.pressedOpacity,
  });

  @override
  State<IosPressSlideMenuAnchor> createState() => _IosPressSlideMenuAnchorState();
}

class _IosPressSlideMenuAnchorState extends State<IosPressSlideMenuAnchor>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _barrierEntry;
  OverlayEntry? _entry;
  FocusScopeNode? _menuFocusScopeNode;
  FocusNode? _previousFocusNode;
  AnimationController? _menuAnimCtrl;
  bool _anchorPressed = false;
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final ValueNotifier<String?> _hoveredId = ValueNotifier<String?>(null);
  List<IosSlideMenuAction> _currentItems = const <IosSlideMenuAction>[];
  bool _longPressActive = false;
  bool _movedOutsideAnchor = false;
  bool _actionDispatched = false;
  Rect _anchorRect = Rect.zero;
  Rect _menuRect = Rect.zero;
  final GlobalKey _menuBoxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (_entry != null) {
      _dismissMenu(immediate: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissMenu(immediate: true);
    _menuAnimCtrl?.dispose();
    _menuAnimCtrl = null;
    _hoveredId.dispose();
    super.dispose();
  }

  Rect _measureAnchorRect() {
    final render = _anchorKey.currentContext?.findRenderObject();
    if (render is RenderBox && render.hasSize && render.attached) {
      final topLeft = render.localToGlobal(Offset.zero);
      return topLeft & render.size;
    }
    return Rect.zero;
  }

  void _dismissMenu({bool immediate = false}) {
    final barrierEntry = _barrierEntry;
    _barrierEntry = null;
    final entry = _entry;
    _entry = null;
    _hoveredId.value = null;
    _longPressActive = false;
    _movedOutsideAnchor = false;
    _rowKeys.clear();
    _menuAnimCtrl?.stop();
    final scopeNode = _menuFocusScopeNode;
    _menuFocusScopeNode = null;
    final restoreFocus = _previousFocusNode;
    _previousFocusNode = null;
    if (entry != null) {
      try {
        entry.remove();
      } catch (_) {}
    }
    if (barrierEntry != null) {
      try {
        barrierEntry.remove();
      } catch (_) {}
    }
    scopeNode?.dispose();
    if (mounted && restoreFocus != null && restoreFocus.canRequestFocus) {
      try {
        restoreFocus.requestFocus();
      } catch (_) {}
    }
  }

  void _dispatchOnce(String id) {
    if (_actionDispatched) return;
    _actionDispatched = true;
    _dismissMenu(immediate: true);
    HapticFeedback.selectionClick();
    widget.onSelected(id);
  }

  void _openMenu({required bool fromLongPress}) {
    if (!widget.enabled || !mounted) return;
    final items = widget.itemsBuilder();
    if (items.isEmpty) return;

    _dismissMenu(immediate: true);
    _actionDispatched = false;
    _longPressActive = fromLongPress;
    _movedOutsideAnchor = false;
    _currentItems = items;
    _anchorRect = _measureAnchorRect();
    _rowKeys.clear();
    for (final item in items) {
      _rowKeys[item.id] = GlobalKey();
    }

    HapticFeedback.lightImpact();
    final overlay = Overlay.of(context, rootOverlay: true);
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations;
    final screen = media.size;
    final safe = media.padding;
    final textScale = (media.textScaler.scale(14.0) / 14.0).clamp(1.0, 4.0);

    final estimatedItemCount = items.length;
    final sectionHeaders = <int>{};
    var extraHeaderCount = 0;
    for (final it in items) {
      if (it.sectionTitle != null &&
          it.sectionTitle!.isNotEmpty &&
          sectionHeaders.add(it.section)) {
        extraHeaderCount++;
      }
    }
    final scaledWidth = widget.menuWidth * math.min(textScale, 1.35);
    final menuW = math.min(scaledWidth, math.max(160.0, screen.width - 24.0));
    final estRowH = math.max(44.0, 26.0 * textScale + 18.0);
    final estHeaderH = math.max(24.0, 14.0 * textScale + 10.0);
    final estRawH =
        estimatedItemCount * estRowH + extraHeaderCount * estHeaderH + 18.0;

    final safeTopEdge = safe.top + 8.0;
    final safeBottomEdge = screen.height - safe.bottom - 8.0;
    final spaceAbove = math.max(0.0, (_anchorRect.top - 10.0) - safeTopEdge);
    final spaceBelow = math.max(0.0, safeBottomEdge - (_anchorRect.bottom + 8.0));
    final openUpward = widget.preferredAnchor.y < 0
        ? (spaceAbove >= math.min(estRawH, 180.0) || spaceAbove >= spaceBelow)
        : (spaceBelow < math.min(estRawH, 180.0) && spaceAbove > spaceBelow);

    final double? positionedTop;
    final double? positionedBottom;
    final double availableMaxH;
    if (openUpward) {
      final anchorBottomY = (_anchorRect.top - 10.0)
          .clamp(safeTopEdge + 120.0, safeBottomEdge)
          .toDouble();
      positionedTop = null;
      positionedBottom = screen.height - anchorBottomY;
      availableMaxH = math.max(120.0, anchorBottomY - safeTopEdge);
    } else {
      final anchorTopY = (_anchorRect.bottom + 8.0)
          .clamp(safeTopEdge, math.max(safeTopEdge, safeBottomEdge - 120.0))
          .toDouble();
      positionedTop = anchorTopY;
      positionedBottom = null;
      availableMaxH = math.max(120.0, safeBottomEdge - anchorTopY);
    }
    final estH = math.min(availableMaxH, estRawH);

    double left;
    if (widget.preferredAnchor.x > 0) {
      left = _anchorRect.right - menuW;
    } else if (widget.preferredAnchor.x < 0) {
      left = _anchorRect.left;
    } else {
      left = _anchorRect.center.dx - menuW * 0.5;
    }
    left = left.clamp(12.0, math.max(12.0, screen.width - menuW - 12.0));
    final approxTop = positionedTop ??
        math.max(safeTopEdge, screen.height - (positionedBottom ?? 0.0) - estH);
    _menuRect = Rect.fromLTWH(left, approxTop, menuW, estH);

    final originAlignment = Alignment(
      widget.preferredAnchor.x > 0
          ? 0.85
          : (widget.preferredAnchor.x < 0 ? -0.85 : 0.0),
      openUpward ? 1.0 : -1.0,
    );

    _previousFocusNode = FocusManager.instance.primaryFocus;
    final menuScopeNode = FocusScopeNode(debugLabel: 'IosPressSlideMenuScope');
    _menuFocusScopeNode = menuScopeNode;

    final animCtrl = _menuAnimCtrl ??= AnimationController(
      vsync: this,
      duration: MotionTokens.durationFast,
    );
    animCtrl.value = 0.0;
    late final OverlayEntry createdBarrierEntry;
    late final OverlayEntry createdEntry;
    createdBarrierEntry = OverlayEntry(
      builder: (_) {
        return AnimatedBuilder(
          animation: animCtrl,
          builder: (_, __) {
            final alpha = (_entry != createdEntry && animCtrl.value <= 0.001)
                ? 0.0
                : (0.14 * animCtrl.value.clamp(0.0, 1.0));
            return ModalBarrier(
              dismissible: true,
              barrierSemanticsDismissible: true,
              semanticsLabel: '关闭菜单',
              color: Colors.black.withValues(alpha: alpha),
              onDismiss: _dismissMenu,
            );
          },
        );
      },
    );
    createdEntry = OverlayEntry(
      builder: (overlayCtx) {
        final palette = ApplePalette.of(overlayCtx);
        final isDark = palette.isDark;
        return FocusScope(
          node: menuScopeNode,
          autofocus: true,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    _dismissMenu(immediate: true);
                    return null;
                  },
                ),
              },
              child: Focus(
                autofocus: true,
                child: Semantics(
                  scopesRoute: true,
                  explicitChildNodes: true,
                  child: Stack(
                    children: [
                      Positioned(
                        left: left,
                        top: positionedTop,
                        bottom: positionedBottom,
                        width: menuW,
                        child: AnimatedBuilder(
                          animation: animCtrl,
                          builder: (_, menuChild) {
                            final t = animCtrl.value.clamp(0.0, 1.0);
                            if (_entry != createdEntry && t <= 0.001) {
                              return const SizedBox.shrink();
                            }
                            final scale = reduceMotion
                                ? 1.0
                                : (0.88 + 0.12 * animCtrl.value);
                      return Opacity(
                        opacity: t,
                        child: Transform.scale(
                          scale: scale,
                          alignment: originAlignment,
                          child: menuChild,
                        ),
                      );
                    },
                    child: Material(
                      type: MaterialType.transparency,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: availableMaxH),
                  child: KeyedSubtree(
                    key: _menuBoxKey,
                    child: LiquidGlass(
                      key: widget.menuKey ?? const ValueKey('ios-slide-menu-surface'),
                      width: menuW,
                      borderRadius: 22,
                      tint: isDark
                          ? const Color(0xCC181820)
                          : const Color(0xF5FFFFFF),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: ValueListenableBuilder<String?>(
                          valueListenable: _hoveredId,
                          builder: (ctx, hovered, _) {
                            final rows = <Widget>[];
                            int? lastSection;
                            for (final item in _currentItems) {
                              if (lastSection != null &&
                                  lastSection != item.section) {
                                rows.add(
                                  Divider(
                                    height: 1,
                                    thickness: 0.5,
                                    color: palette.separator,
                                  ),
                                );
                              }
                              if (lastSection != item.section &&
                                  item.sectionTitle != null &&
                                  item.sectionTitle!.isNotEmpty) {
                                rows.add(
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      7,
                                      14,
                                      3,
                                    ),
                                    child: Text(
                                      item.sectionTitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: palette.labelSecondary,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              lastSection = item.section;
                              final isHovered = hovered == item.id;
                              final fg = item.destructive
                                  ? AppleColors.systemRed
                                  : (item.selected || isHovered
                                      ? (isDark
                                          ? Colors.white
                                          : palette.systemBlue)
                                      : palette.labelPrimary);
                              rows.add(
                                Semantics(
                                  button: true,
                                  selected: item.selected,
                                  label: item.title,
                                  child: GestureDetector(
                                    key: _rowKeys[item.id],
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _dispatchOnce(item.id),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 90),
                                      constraints: const BoxConstraints(
                                        minHeight: 44,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 9,
                                      ),
                                      color: isHovered
                                          ? (isDark
                                              ? Colors.white
                                                  .withValues(alpha: 0.14)
                                              : AppleColors.systemBlue
                                                  .withValues(alpha: 0.12))
                                          : Colors.transparent,
                                      child: Row(
                                        children: [
                                          if (item.icon != null) ...[
                                            Icon(item.icon, size: 18, color: fg),
                                            const SizedBox(width: 10),
                                          ],
                                          Expanded(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: fg,
                                                    fontSize: 14,
                                                    fontWeight: item.selected ||
                                                            isHovered
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                                if (item.subtitle != null &&
                                                    item.subtitle!
                                                        .isNotEmpty) ...[
                                                  const SizedBox(height: 1.5),
                                                  Text(
                                                    item.subtitle!,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: palette
                                                          .labelSecondary,
                                                      fontSize: 11.5,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (item.selected)
                                            Icon(
                                              CupertinoIcons.checkmark_alt,
                                              size: 15,
                                              color: fg,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: rows,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
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
    );
      },
    );
    _barrierEntry = createdBarrierEntry;
    _entry = createdEntry;
    overlay.insertAll(<OverlayEntry>[createdBarrierEntry, createdEntry]);
    Ios27Spring.animate(
      animCtrl,
      spring: Ios27Spring.snappy,
      target: 1.0,
      disableAnimations: reduceMotion,
    );
  }

  String? _hitTestItem(Offset globalPos) {
    for (final entry in _rowKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.contains(globalPos)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  bool _insideMenu(Offset globalPos) {
    final box = _menuBoxKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      return rect.contains(globalPos);
    }
    return _menuRect.contains(globalPos);
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    if (!widget.enabled) return;
    _openMenu(fromLongPress: true);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_longPressActive || _entry == null) return;
    final pos = details.globalPosition;
    if (!_anchorRect.inflate(8).contains(pos)) {
      _movedOutsideAnchor = true;
    }
    final hitId = _hitTestItem(pos);
    if (hitId != _hoveredId.value) {
      _hoveredId.value = hitId;
      if (hitId != null) {
        HapticFeedback.selectionClick();
      }
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (!_longPressActive) return;
    _longPressActive = false;
    if (_entry == null) return;
    final pos = details.globalPosition;
    final hitId = _hitTestItem(pos) ?? _hoveredId.value;
    if (hitId != null && _insideMenu(pos)) {
      _dispatchOnce(hitId);
      return;
    }
    if (_movedOutsideAnchor && !_insideMenu(pos)) {
      // User dragged outside both the anchor and menu -> cancel cleanly.
      _dismissMenu();
      return;
    }
    // User lifted finger on the anchor without sliding onto an item ->
    // keep the menu open so they can tap any item.
    _hoveredId.value = null;
  }

  void _handleLongPressCancel() {
    if (_longPressActive) {
      _longPressActive = false;
    }
  }

  void _handleTap() {
    if (!widget.enabled) return;
    if (_entry != null) {
      _dismissMenu();
      return;
    }
    if (widget.openOnTap) {
      _openMenu(fromLongPress: false);
    } else {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final pressedOpacity =
        widget.pressedOpacity ?? (reduceMotion ? 0.72 : 1.0);
    Widget inner = AnimatedScale(
      scale: (!reduceMotion && _anchorPressed) ? widget.pressedScale : 1.0,
      duration: MotionTokens.durationMicro,
      curve: MotionTokens.curveStandard,
      child: AnimatedOpacity(
        opacity: _anchorPressed ? pressedOpacity : 1.0,
        duration: MotionTokens.durationMicro,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: widget.minTouchWidth,
            minHeight: widget.minTouchHeight,
          ),
          child: Center(
            widthFactor: 1.0,
            heightFactor: 1.0,
            child: widget.child,
          ),
        ),
      ),
    );
    Widget body = GestureDetector(
      key: _anchorKey,
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => setState(() => _anchorPressed = true) : null,
      onTapUp: widget.enabled ? (_) => setState(() => _anchorPressed = false) : null,
      onTapCancel: widget.enabled ? () => setState(() => _anchorPressed = false) : null,
      onTap: widget.enabled ? _handleTap : null,
      onLongPressStart: widget.enabled
          ? (d) {
              if (_anchorPressed) setState(() => _anchorPressed = false);
              _handleLongPressStart(d);
            }
          : null,
      onLongPressMoveUpdate: widget.enabled ? _handleLongPressMoveUpdate : null,
      onLongPressEnd: widget.enabled ? _handleLongPressEnd : null,
      onLongPressCancel: widget.enabled ? _handleLongPressCancel : null,
      child: inner,
    );
    final hasLabel =
        widget.accessibilityLabel != null && widget.accessibilityLabel!.isNotEmpty;
    if (hasLabel || !widget.openOnTap) {
      body = Semantics(
        button: true,
        label: hasLabel ? widget.accessibilityLabel : null,
        hint: widget.accessibilityHint ??
            (widget.openOnTap ? '轻点打开导航菜单' : '轻点切换，长按或使用操作转轮查看更多选项'),
        onTap: widget.enabled ? _handleTap : null,
        onLongPress: widget.enabled && !widget.openOnTap
            ? () => _openMenu(fromLongPress: false)
            : null,
        customSemanticsActions: widget.enabled && !widget.openOnTap
            ? <CustomSemanticsAction, VoidCallback>{
                const CustomSemanticsAction(label: '更多操作'): () =>
                    _openMenu(fromLongPress: false),
              }
            : null,
        child: body,
      );
    }
    return body;
  }
}

/// Converts a list of [IosNativeMenuItem] into [IosSlideMenuAction] so native
/// `UIMenu` and Flutter fallback menus share one single definition.
List<IosSlideMenuAction> iosSlideActionsFromNativeMenu(
  List<IosNativeMenuItem> items, {
  IconData? Function(String? symbol)? iconResolver,
}) {
  return [
    for (final item in items)
      IosSlideMenuAction(
        id: item.id,
        title: item.title,
        subtitle: item.subtitle,
        icon: iconResolver?.call(item.symbol) ??
            _defaultIconForMenuSymbol(item.symbol),
        selected: item.checked,
        destructive: item.destructive,
        section: item.section,
        sectionTitle: item.sectionTitle,
      ),
  ];
}

IconData? _defaultIconForMenuSymbol(String? symbol) => switch (symbol) {
      'magnifyingglass' => CupertinoIcons.search,
      'house' || 'house.fill' => CupertinoIcons.house_fill,
      'play.tv' || 'play.tv.fill' => CupertinoIcons.tv_fill,
      'rectangle.stack' ||
      'rectangle.stack.fill' =>
        CupertinoIcons.rectangle_stack_fill,
      'gearshape' || 'gearshape.fill' => CupertinoIcons.gear_alt_fill,
      'arrow.up.to.line' => CupertinoIcons.arrow_up_to_line,
      'heart' || 'heart.fill' => CupertinoIcons.heart_fill,
      'clock' || 'clock.fill' => CupertinoIcons.clock_fill,
      'plus.circle' || 'plus.circle.fill' || 'plus' => CupertinoIcons.add_circled,
      'cloud' || 'cloud.fill' => CupertinoIcons.cloud_fill,
      'folder' || 'folder.fill' => CupertinoIcons.folder_fill,
      'link' || 'tray.full' || 'tray.full.fill' => CupertinoIcons.tray_full_fill,
      'antenna.radiowaves.left.and.right' ||
      'dot.radiowaves.left.and.right' =>
        CupertinoIcons.dot_radiowaves_left_right,
      'star.fill' => CupertinoIcons.star_fill,
      'lock.shield' || 'lock.shield.fill' => CupertinoIcons.lock_shield_fill,
      'archivebox' || 'archivebox.fill' => CupertinoIcons.archivebox_fill,
      'shippingbox' => CupertinoIcons.cube_box_fill,
      'slider.horizontal.3' => CupertinoIcons.slider_horizontal_3,
      _ => null,
    };

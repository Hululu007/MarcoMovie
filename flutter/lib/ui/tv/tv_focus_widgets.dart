// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lan_sync_server.dart';
import '../../core/models.dart';
import '../../core/storage_service.dart';
import '../local_qr_code.dart';
import '../poster_image.dart';
import 'tv_ambient_theme.dart';

bool isTvActivationKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA;
}

/// High-contrast 10-foot focusable glass pill/tile designed for D-pad / TV remotes,
/// matching Apple TV's translucent frosted-glass language over living-room ambient themes.
class TvFocusPill extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onFocusGained;
  final bool selected;
  final bool prominent;
  final bool glass;
  final bool destructive;
  final bool preserveColorsOnFocus;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? backgroundColor;
  final String? semanticLabel;

  const TvFocusPill({
    super.key,
    required this.child,
    this.onSelect,
    this.onFocusGained,
    this.selected = false,
    this.prominent = false,
    this.glass = false,
    this.destructive = false,
    this.preserveColorsOnFocus = false,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    this.borderRadius = 999,
    this.backgroundColor,
    this.semanticLabel,
  });

  @override
  State<TvFocusPill> createState() => _TvFocusPillState();
}

class _TvFocusPillState extends State<TvFocusPill> {
  bool _focused = false;
  bool _hovered = false;

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    final disabled = widget.onSelect == null;
    final Color bg;
    final Color borderColor;
    final Color fgColor;
    final List<BoxShadow>? shadows;

    if (widget.prominent) {
      bg = disabled
          ? Colors.white.withValues(alpha: 0.14)
          : (active ? Colors.white : const Color(0xF5F7F9FC));
      borderColor = _focused
          ? TvAmbientColors.accent
          : Colors.white.withValues(alpha: disabled ? 0.16 : 0.85);
      fgColor = disabled
          ? Colors.white.withValues(alpha: 0.45)
          : TvAmbientColors.darkInk;
      shadows = _focused
          ? [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.36),
                blurRadius: 24,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: TvAmbientColors.accent.withValues(alpha: 0.44),
                blurRadius: 26,
                offset: const Offset(0, 8),
              ),
            ]
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.34),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ];
    } else if (widget.destructive) {
      bg = widget.backgroundColor ??
          (active
              ? const Color(0xFFE5484D)
              : const Color(0x38FF453A));
      borderColor = _focused
          ? Colors.white
          : const Color(0x70FF6961);
      fgColor = active ? Colors.white : const Color(0xFFFFB7B3);
      shadows = _focused
          ? [
              BoxShadow(
                color: const Color(0xFFE5484D).withValues(alpha: 0.45),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ]
          : null;
    } else if (widget.glass) {
      bg = widget.backgroundColor ??
          (active && !widget.preserveColorsOnFocus
              ? Colors.white
              : (widget.selected
                  ? TvAmbientColors.accent.withValues(alpha: 0.90)
                  : Colors.white.withValues(alpha: active ? 0.20 : 0.12)));
      borderColor = _focused
          ? Colors.white
          : (widget.selected
              ? Colors.white.withValues(alpha: 0.48)
              : TvAmbientColors.glassStroke);
      fgColor = (active && !widget.preserveColorsOnFocus)
          ? TvAmbientColors.darkInk
          : Colors.white;
      shadows = _focused
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.46),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ]
          : null;
    } else {
      bg = widget.backgroundColor ??
          (widget.selected
              ? TvAmbientColors.accent
              : (active && !widget.preserveColorsOnFocus
                  ? TvAmbientColors.accent
                  : Colors.white.withValues(alpha: active ? 0.19 : 0.11)));
      borderColor = _focused
          ? Colors.white
          : (widget.selected
              ? Colors.white.withValues(alpha: 0.42)
              : TvAmbientColors.glassStroke);
      fgColor = Colors.white;
      shadows = _focused
          ? [
              BoxShadow(
                color: TvAmbientColors.accent.withValues(alpha: 0.45),
                blurRadius: 20,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
            ]
          : (widget.selected
              ? [
                  BoxShadow(
                    color: TvAmbientColors.accent.withValues(alpha: 0.28),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null);
    }

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        canRequestFocus: widget.onSelect != null,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused) {
            _ensureVisible();
            widget.onFocusGained?.call();
          }
        },
        onKeyEvent: (node, event) {
          if (widget.onSelect != null &&
              event is KeyDownEvent &&
              isTvActivationKey(event.logicalKey)) {
            widget.onSelect!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: widget.onSelect != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: AnimatedScale(
              scale: _focused ? 1.045 : 1.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: Container(
                padding: widget.padding,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  border: Border.all(
                    color: borderColor,
                    width: _focused ? 2.4 : 1.1,
                  ),
                  boxShadow: shadows,
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: fgColor),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: fgColor,
                      fontWeight:
                          (widget.prominent || _focused || widget.selected)
                              ? FontWeight.w700
                              : FontWeight.w600,
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 16:9 widescreen Continue Watching cinema card matching Apple TV's `ContinueWatchingCard`.
class TvWideContinueCard extends StatefulWidget {
  final WatchHistoryEntry entry;
  final VoidCallback onSelect;
  final VoidCallback? onFocusGained;
  final bool autofocus;

  const TvWideContinueCard({
    super.key,
    required this.entry,
    required this.onSelect,
    this.onFocusGained,
    this.autofocus = false,
  });

  @override
  State<TvWideContinueCard> createState() => _TvWideContinueCardState();
}

class _TvWideContinueCardState extends State<TvWideContinueCard> {
  bool _focused = false;
  bool _hovered = false;

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    final pct = (widget.entry.progressFraction * 100).round().clamp(0, 100);
    final sub = widget.entry.episode.isEmpty
        ? '继续播放 · 已看 $pct%'
        : '${widget.entry.episode} · 已看 $pct%';

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          _ensureVisible();
          widget.onFocusGained?.call();
        }
      },
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent && isTvActivationKey(event.logicalKey)) {
          widget.onSelect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: AnimatedScale(
            scale: active ? 1.04 : 1.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: SizedBox(
              width: 268,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 268,
                    height: 150,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: active
                            ? Colors.white
                            : TvAmbientColors.glassStroke,
                        width: active ? 2.5 : 1.1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: active ? 0.55 : 0.28,
                          ),
                          blurRadius: active ? 20 : 10,
                          offset: Offset(0, active ? 8 : 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14.5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          PosterImage(
                            url: widget.entry.poster,
                            title: widget.entry.title,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: const Color(0xFF1A2232),
                              alignment: Alignment.center,
                              child: Icon(
                                CupertinoIcons.film,
                                color: Colors.white.withValues(alpha: 0.30),
                                size: 32,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              height: 5,
                              color: Colors.black.withValues(alpha: 0.62),
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: widget.entry.progressFraction
                                    .clamp(0.0, 1.0),
                                child: Container(
                                  color: TvAmbientColors.accent,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    widget.entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TvAmbientColors.secondaryText,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 10-foot vertical 2:3 cinema poster card with Apple TV-parity frosted stroke,
/// luminous focus lift, score/remarks capsule badge, and metadata subtitle.
class TvFocusablePosterCard extends StatefulWidget {
  final CmsVideo video;
  final String subtitleBadge;
  final String? sourceSubtitle;
  final double progressFraction;
  final VoidCallback onSelect;
  final VoidCallback? onFocusGained;
  final bool autofocus;

  const TvFocusablePosterCard({
    super.key,
    required this.video,
    required this.onSelect,
    this.subtitleBadge = '',
    this.sourceSubtitle,
    this.progressFraction = 0.0,
    this.onFocusGained,
    this.autofocus = false,
  });

  @override
  State<TvFocusablePosterCard> createState() => _TvFocusablePosterCardState();
}

class _TvFocusablePosterCardState extends State<TvFocusablePosterCard> {
  bool _focused = false;
  bool _hovered = false;

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.35,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String _resolveMetaLine() {
    if (widget.sourceSubtitle != null && widget.sourceSubtitle!.isNotEmpty) {
      return widget.sourceSubtitle!;
    }
    final parts = <String>[
      if (widget.video.year.trim().isNotEmpty) widget.video.year.trim(),
      if (widget.video.tag.trim().isNotEmpty)
        widget.video.tag.trim()
      else if (widget.video.area.trim().isNotEmpty)
        widget.video.area.trim(),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    final badge = widget.subtitleBadge.isNotEmpty
        ? widget.subtitleBadge
        : widget.video.remarks;
    final metaLine = _resolveMetaLine();

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          _ensureVisible();
          widget.onFocusGained?.call();
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && isTvActivationKey(event.logicalKey)) {
          widget.onSelect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: AnimatedScale(
            scale: active ? 1.045 : 1.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: active
                            ? Colors.white
                            : TvAmbientColors.glassStroke,
                        width: active ? 2.5 : 1.1,
                      ),
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.58),
                                blurRadius: 22,
                                offset: const Offset(0, 10),
                              ),
                              BoxShadow(
                                color: TvAmbientColors.accent
                                    .withValues(alpha: 0.32),
                                blurRadius: 20,
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.28),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14.5),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          PosterImage(
                            url: widget.video.poster,
                            title: widget.video.title,
                            year: widget.video.year,
                            placeholder: Container(
                              color: const Color(0xFF1A2232),
                              alignment: Alignment.center,
                              padding: const EdgeInsets.all(10),
                              child: Icon(
                                CupertinoIcons.film,
                                color: Colors.white.withValues(alpha: 0.28),
                                size: 32,
                              ),
                            ),
                          ),
                          if (badge.isNotEmpty)
                            Positioned(
                              right: 10,
                              top: 10,
                              child: Container(
                                constraints: const BoxConstraints(maxWidth: 160),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.18),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  badge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          if (widget.progressFraction > 0.01)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: widget.progressFraction.clamp(0.0, 1.0),
                                minHeight: 4.5,
                                backgroundColor: Colors.black54,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  TvAmbientColors.accent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  widget.video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.94),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (metaLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    metaLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TvAmbientColors.mutedText,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Built-in Apple TV-parity living-room remote search keyboard with frosted-glass panel,
/// `ABC 拼音` / `123 数字` toggle, backspace, clear, search CTA, and recent history pills.
class TvRemoteGridKeyboard extends StatefulWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onSubmit;
  final VoidCallback? onClearHistory;
  final List<String> history;

  const TvRemoteGridKeyboard({
    super.key,
    required this.query,
    required this.onQueryChanged,
    required this.onSubmit,
    this.onClearHistory,
    this.history = const [],
  });

  @override
  State<TvRemoteGridKeyboard> createState() => _TvRemoteGridKeyboardState();
}

class _TvRemoteGridKeyboardState extends State<TvRemoteGridKeyboard> {
  static const List<String> _alphaKeys = <String>[
    'A', 'B', 'C', 'D', 'E', 'F',
    'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R',
    'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', ' ', '-', '1', '2',
  ];

  static const List<String> _digitKeys = <String>[
    '1', '2', '3', '4', '5', '6',
    '7', '8', '9', '0', 'S', 'E',
  ];

  bool _digitMode = false;

  @override
  Widget build(BuildContext context) {
    final keys = _digitMode ? _digitKeys : _alphaKeys;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.085),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: TvAmbientColors.glassStroke, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '多站聚合搜索',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: TvAmbientColors.glassStroke, width: 1.1),
            ),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.search,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.query.isEmpty ? '输入片名或首字母检索' : widget.query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.query.isEmpty
                          ? TvAmbientColors.mutedText
                          : Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.mic_fill,
                        size: 13,
                        color: TvAmbientColors.secondaryText,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '遥控首拼',
                        style: TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              TvFocusPill(
                selected: !_digitMode,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                onSelect: () => setState(() => _digitMode = false),
                child: const Text('ABC 拼音', style: TextStyle(fontSize: 14)),
              ),
              const SizedBox(width: 10),
              TvFocusPill(
                selected: _digitMode,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                onSelect: () => setState(() => _digitMode = true),
                child: const Text('123 数字', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: keys.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 9,
              crossAxisSpacing: 9,
              childAspectRatio: 1.18,
            ),
            itemBuilder: (context, index) {
              final ch = keys[index];
              final label = ch == ' ' ? '空格' : ch;
              return TvFocusPill(
                padding: EdgeInsets.zero,
                borderRadius: 12,
                onSelect: () => widget.onQueryChanged('${widget.query}$ch'),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: ch == ' ' ? 13 : 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  onSelect: () {
                    if (widget.query.isNotEmpty) {
                      widget.onQueryChanged(
                        widget.query.substring(0, widget.query.length - 1),
                      );
                    }
                  },
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.delete_left, size: 16),
                      SizedBox(width: 5),
                      Text('退格', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  onSelect: () => widget.onQueryChanged(''),
                  child: const Center(
                    child: Text('清空', style: TextStyle(fontSize: 14)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  selected: true,
                  onSelect: widget.onSubmit,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(CupertinoIcons.search, size: 15),
                      SizedBox(width: 5),
                      Text('搜索', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (widget.history.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                const Text(
                  '最近搜索',
                  style: TextStyle(
                    color: TvAmbientColors.secondaryText,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (widget.onClearHistory != null)
                  TvFocusPill(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    onSelect: widget.onClearHistory,
                    child: const Text('清除', style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in widget.history.take(6))
                  TvFocusPill(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    onSelect: () {
                      widget.onQueryChanged(item);
                      widget.onSubmit();
                    },
                    child: Text(item, style: const TextStyle(fontSize: 13.5)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Modal dialog displaying a local LAN HTTP QR code (`LanSyncServer`) so users
/// on a Smart Screen / TV can push config URLs or sync backups from their phone.
class TvQrSyncDialog extends StatefulWidget {
  final StorageService storage;
  final VoidCallback onConfigChanged;

  const TvQrSyncDialog({
    super.key,
    required this.storage,
    required this.onConfigChanged,
  });

  @override
  State<TvQrSyncDialog> createState() => _TvQrSyncDialogState();
}

class _TvQrSyncDialogState extends State<TvQrSyncDialog> {
  LanSyncServer? _server;
  String _lanUrl = '';
  String _lanQrPayload = '';
  String _status = '正在启动局域网配置接收服务…';

  @override
  void initState() {
    super.initState();
    unawaited(_startServer());
  }

  @override
  void dispose() {
    final s = _server;
    _server = null;
    if (s != null) {
      unawaited(s.close(force: true));
    }
    super.dispose();
  }

  Future<String> _detectLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && LanSyncServer.isAllowedPeerAddress(addr)) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> _startServer() async {
    final prev = _server;
    _server = null;
    if (prev != null) {
      await prev.close(force: true);
    }
    try {
      final host = await _detectLanIpv4();
      final server = await LanSyncServer.start(
        widget.storage,
        onSynced: ({
          required int historyCount,
          required int favoriteCount,
          required int subscriptionCount,
          required bool changed,
          required bool subscriptionsChanged,
        }) {
          if (!mounted) {
            return;
          }
          setState(() {
            _status =
                '已接收同步：订阅 $subscriptionCount 项 · 历史 $historyCount 条 · 收藏 $favoriteCount 条';
          });
          if (changed || subscriptionsChanged) {
            widget.onConfigChanged();
          }
        },
        onWebdavBound: (url) {
          if (!mounted) {
            return;
          }
          setState(() {
            _status = '已扫码自动绑定 WebDAV（$url）';
          });
          widget.onConfigChanged();
          if (widget.storage.webdavAuto) {
            unawaited(
              widget.storage.syncWithWebdav().then(
                (_) {
                  if (mounted) {
                    widget.onConfigChanged();
                  }
                },
                onError: (_) {},
              ),
            );
          }
        },
      );
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      setState(() {
        _server = server;
        _lanUrl = server.addressForHost(host);
        _lanQrPayload = server.bindQrUrlForHost(host);
        _status = '请使用同一 Wi-Fi / 局域网下的手机端 App 或浏览器扫码推送配置或绑定 WebDAV';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '局域网服务启动失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xEB101928),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: TvAmbientColors.glassStroke, width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '手机扫码推送配置与跨端同步',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: TvAmbientColors.secondaryText,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 24),
              if (_lanUrl.isNotEmpty)
                Container(
                  width: 224,
                  height: 224,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: LocalQrCode(
                    data: _lanQrPayload.isNotEmpty ? _lanQrPayload : _lanUrl,
                  ),
                )
              else
                const SizedBox(
                  height: 180,
                  child: Center(child: CupertinoActivityIndicator(radius: 16)),
                ),
              if (_lanUrl.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(
                  _lanUrl,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: TvAmbientColors.accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TvFocusPill(
                    onSelect: _startServer,
                    child: const Text('刷新二维码'),
                  ),
                  const SizedBox(width: 16),
                  TvFocusPill(
                    autofocus: true,
                    selected: true,
                    onSelect: () => Navigator.of(context).pop(),
                    child: const Text('完成关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lan_sync_server.dart';
import '../../core/models.dart';
import '../../core/storage_service.dart';
import '../apple_theme.dart';
import '../local_qr_code.dart';
import '../poster_image.dart';

bool isTvActivationKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA;
}

/// High-contrast 10-foot focusable pill/button designed for D-pad / TV remotes.
class TvFocusPill extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onFocusGained;
  final bool selected;
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
    final bg = widget.backgroundColor ??
        (active
            ? AppleColors.systemBlue
            : (widget.selected
                ? AppleColors.systemBlue.withValues(alpha: 0.28)
                : const Color(0xFF23252B)));
    final borderColor = _focused
        ? Colors.white
        : (widget.selected
            ? AppleColors.systemBlue.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.12));

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
              scale: _focused ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: widget.padding,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  border: Border.all(
                    color: borderColor,
                    width: _focused ? 2.5 : 1.2,
                  ),
                  boxShadow: _focused
                      ? [
                          BoxShadow(
                            color: AppleColors.systemBlue.withValues(alpha: 0.45),
                            blurRadius: 18,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: _focused ? Colors.white : AppleColors.labelPrimary,
                    fontWeight:
                        (_focused || widget.selected) ? FontWeight.w700 : FontWeight.w500,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 10-foot vertical poster card with luminous D-pad focus ring, 1.06x zoom,
/// remarks badge, and optional watch-progress bar.
class TvFocusablePosterCard extends StatefulWidget {
  final CmsVideo video;
  final String subtitleBadge;
  final double progressFraction;
  final VoidCallback onSelect;
  final VoidCallback? onFocusGained;
  final bool autofocus;

  const TvFocusablePosterCard({
    super.key,
    required this.video,
    required this.onSelect,
    this.subtitleBadge = '',
    this.progressFraction = 0.0,
    this.onFocusGained,
    this.autofocus = false,
  });

  @override
  State<TvFocusablePosterCard> createState() => _TvFocusablePosterCardState();
}

class _TvFocusablePosterCardState extends State<TvFocusablePosterCard> {
  bool _focused = false;

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

  @override
  Widget build(BuildContext context) {
    final badge = widget.subtitleBadge.isNotEmpty
        ? widget.subtitleBadge
        : widget.video.remarks;
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: AnimatedScale(
          scale: _focused ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _focused
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.10),
                      width: _focused ? 3.0 : 1.0,
                    ),
                    boxShadow: _focused
                        ? [
                            BoxShadow(
                              color: AppleColors.systemBlue.withValues(alpha: 0.55),
                              blurRadius: 24,
                              spreadRadius: 2,
                            ),
                          ]
                        : const [
                            BoxShadow(
                              color: Color(0x55000000),
                              blurRadius: 10,
                              offset: Offset(0, 4),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        PosterImage(
                          url: widget.video.poster,
                          title: widget.video.title,
                          year: widget.video.year,
                          placeholder: Container(
                            color: const Color(0xFF1D1F26),
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
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
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
                              minHeight: 4,
                              backgroundColor: Colors.black45,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppleColors.systemBlue,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _focused ? Colors.white : AppleColors.labelPrimary,
                  fontSize: 14,
                  fontWeight: _focused ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Built-in living-room remote search keyboard supporting letters, digits,
/// Pinyin initials, backspace, clear, and search history pills.
class TvRemoteGridKeyboard extends StatelessWidget {
  static const List<String> _keys = <String>[
    'A', 'B', 'C', 'D', 'E', 'F',
    'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R',
    'S', 'T', 'U', 'V', 'W', 'X',
    'Y', 'Z', '1', '2', '3', '4',
    '5', '6', '7', '8', '9', '0',
  ];

  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onSubmit;
  final List<String> history;

  const TvRemoteGridKeyboard({
    super.key,
    required this.query,
    required this.onQueryChanged,
    required this.onSubmit,
    this.history = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF171920),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1116),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              children: [
                const Icon(
                  CupertinoIcons.search,
                  color: AppleColors.labelSecondary,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    query.isEmpty ? '支持片名首拼 / 字母 / 数字' : query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: query.isEmpty
                          ? AppleColors.labelTertiary
                          : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  borderRadius: 10,
                  onSelect: () {
                    if (query.isNotEmpty) {
                      onQueryChanged(query.substring(0, query.length - 1));
                    }
                  },
                  child: const Center(child: Text('⌫ 退格')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  borderRadius: 10,
                  onSelect: () => onQueryChanged(''),
                  child: const Center(child: Text('清空')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TvFocusPill(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  borderRadius: 10,
                  selected: true,
                  onSelect: onSubmit,
                  child: const Center(child: Text('搜索')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _keys.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.2,
            ),
            itemBuilder: (context, index) {
              final ch = _keys[index];
              return TvFocusPill(
                padding: EdgeInsets.zero,
                borderRadius: 10,
                onSelect: () => onQueryChanged('$query$ch'),
                child: Center(
                  child: Text(
                    ch,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              '最近搜索',
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in history.take(6))
                  TvFocusPill(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    onSelect: () {
                      onQueryChanged(item);
                      onSubmit();
                    },
                    child: Text(item, style: const TextStyle(fontSize: 13)),
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
      );
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      setState(() {
        _server = server;
        _lanUrl = server.addressForHost(host);
        _status = '请使用同一 Wi-Fi / 局域网下的手机浏览器扫码推送配置或备份';
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
      backgroundColor: const Color(0xFF181A22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '手机扫码推送配置与跨端同步',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 22),
              if (_lanUrl.isNotEmpty)
                Container(
                  width: 220,
                  height: 220,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: LocalQrCode(data: _lanUrl),
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
                    color: AppleColors.systemBlue,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 24),
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

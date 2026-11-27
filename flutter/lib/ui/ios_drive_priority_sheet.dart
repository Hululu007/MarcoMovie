// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/catpaw_host.dart';
import '../core/netdisk_service.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';

/// Canonical playback source priority mode controlled from
/// [PlaybackSourcePriorityEditor].
enum PlaybackSourcePriorityMode {
  netdiskFirst(
    qualityValue: '4k_netdisk',
    titleZh: '网盘原画优先',
    subtitleZh: '优先选择下方排在前面的网盘 4K / 原画线路',
    icon: CupertinoIcons.cloud_fill,
  ),
  directFirst(
    qualityValue: '1080p_direct',
    titleZh: '直连流媒体优先',
    subtitleZh: '优先选择免扫码 M3U8 / MP4 直链，无直链时按盘序兜底',
    icon: CupertinoIcons.bolt_horizontal_circle_fill,
  ),
  siteDefault(
    qualityValue: 'default',
    titleZh: '跟随站点原始顺序',
    subtitleZh: '保持片源站点返回的默认第一条可用线路',
    icon: CupertinoIcons.list_number,
  );

  final String qualityValue;
  final String titleZh;
  final String subtitleZh;
  final IconData icon;

  const PlaybackSourcePriorityMode({
    required this.qualityValue,
    required this.titleZh,
    required this.subtitleZh,
    required this.icon,
  });

  static PlaybackSourcePriorityMode fromStorage(StorageService storage) {
    final q = storage.preferredQuality;
    if (q == '1080p_direct' || q == 'fast_hls') {
      return PlaybackSourcePriorityMode.directFirst;
    }
    if (q == 'default') {
      return PlaybackSourcePriorityMode.siteDefault;
    }
    return PlaybackSourcePriorityMode.netdiskFirst;
  }
}

/// Formats a concise summary string for settings rows and banners, e.g.
/// `网盘优先 · 夸克 > UC > 百度 > 阿里`.
String formatPlaybackSourcePrioritySummary(StorageService storage) {
  final mode = PlaybackSourcePriorityMode.fromStorage(storage);
  if (mode == PlaybackSourcePriorityMode.directFirst) {
    return '直连优先';
  }
  if (mode == PlaybackSourcePriorityMode.siteDefault) {
    return '站点默认';
  }
  final order = storage.effectiveDriveOrder
      .map(StorageService.driveShortLabelZh)
      .join(' > ');
  return order;
}

/// Presents the interactive default playback source & manual netdisk priority
/// editor sheet (`默认播放来源与盘序`).
Future<void> showPlaybackSourcePrioritySheet(
  BuildContext context,
  StorageService storage, {
  VoidCallback? onChanged,
  Future<void> Function()? onSyncExternal,
}) {
  return showIos27LiquidSheet<void>(
    context: context,
    title: '默认播放来源与盘序',
    maxWidth: 560,
    builder: (sheetCtx) => PlaybackSourcePriorityEditor(
      storage: storage,
      onChanged: onChanged,
      onSyncExternal: onSyncExternal,
    ),
  );
}

/// Interactive editor allowing users to:
/// 1. Switch default playback source mode (`网盘原画优先` / `直连流媒体优先` / `跟随站点原始顺序`);
/// 2. One-tap select a default `#1` netdisk source;
/// 3. Manually drag-to-reorder (`ReorderableListView`) or move any netdisk up/down;
/// 4. Toggle automatic prioritization of logged-in netdisks.
class PlaybackSourcePriorityEditor extends StatefulWidget {
  final StorageService storage;
  final VoidCallback? onChanged;
  final Future<void> Function()? onSyncExternal;

  const PlaybackSourcePriorityEditor({
    super.key,
    required this.storage,
    this.onChanged,
    this.onSyncExternal,
  });

  @override
  State<PlaybackSourcePriorityEditor> createState() =>
      _PlaybackSourcePriorityEditorState();
}

class _PlaybackSourcePriorityEditorState
    extends State<PlaybackSourcePriorityEditor> {
  late List<String> _order;
  late PlaybackSourcePriorityMode _mode;
  late bool _prioritizeLoggedIn;

  @override
  void initState() {
    super.initState();
    _reloadFromStorage();
  }

  void _reloadFromStorage() {
    _order = List<String>.from(widget.storage.driveOrder);
    _mode = PlaybackSourcePriorityMode.fromStorage(widget.storage);
    _prioritizeLoggedIn = widget.storage.prioritizeLoggedInDrives;
  }

  void _notifyExternalSync() {
    if (widget.onSyncExternal != null) {
      unawaited(widget.onSyncExternal!());
    } else {
      unawaited(
        CatPawHost.instance.syncNetdiskConfigWithStorage(widget.storage),
      );
    }
    widget.onChanged?.call();
  }

  Future<void> _selectMode(PlaybackSourcePriorityMode next) async {
    HapticFeedback.selectionClick();
    await widget.storage.setAutoHardwareQualityEnabled(false);
    await widget.storage.setPreferredQuality(next.qualityValue);
    if (mounted) {
      setState(() => _mode = next);
    }
    widget.onChanged?.call();
  }

  Future<void> _applyNewOrder(
    List<String> nextOrder, {
    bool promoteToNetdiskMode = false,
  }) async {
    HapticFeedback.selectionClick();
    await widget.storage.setDriveOrder(nextOrder, markCustomized: true);
    if (promoteToNetdiskMode &&
        _mode != PlaybackSourcePriorityMode.netdiskFirst) {
      await widget.storage.setAutoHardwareQualityEnabled(false);
      await widget.storage.setPreferredQuality(
        PlaybackSourcePriorityMode.netdiskFirst.qualityValue,
      );
      _mode = PlaybackSourcePriorityMode.netdiskFirst;
    }
    if (mounted) {
      setState(() => _order = List<String>.from(widget.storage.driveOrder));
    }
    _notifyExternalSync();
  }

  Future<void> _promoteDriveToTop(String driveKey) async {
    final next = <String>[
      driveKey,
      for (final k in _order)
        if (k != driveKey) k,
    ];
    await _applyNewOrder(next, promoteToNetdiskMode: true);
  }

  Future<void> _moveDrive(int index, int delta) async {
    final target = index + delta;
    if (index < 0 ||
        index >= _order.length ||
        target < 0 ||
        target >= _order.length) {
      return;
    }
    final next = List<String>.from(_order);
    final item = next.removeAt(index);
    next.insert(target, item);
    await _applyNewOrder(next);
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (oldIndex == newIndex) return;
    final next = List<String>.from(_order);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    await _applyNewOrder(next);
  }

  Future<void> _togglePrioritizeLoggedIn(bool value) async {
    HapticFeedback.selectionClick();
    await widget.storage.setPrioritizeLoggedInDrives(value);
    if (mounted) {
      setState(() => _prioritizeLoggedIn = value);
    }
    widget.onChanged?.call();
  }

  Future<void> _resetDefaultOrder() async {
    HapticFeedback.lightImpact();
    await widget.storage.resetDriveOrder();
    await widget.storage.setPrioritizeLoggedInDrives(true);
    if (mounted) {
      setState(_reloadFromStorage);
    }
    _notifyExternalSync();
  }

  static NetdiskDriveInfo _specFor(String key) => NetdiskDriveInfo.byKey(key);

  static Color _driveAccentColor(String key) => switch (key) {
    'quark' => const Color(0xFF2B7BFF),
    'uc' => const Color(0xFFFF8A00),
    'baidu' => const Color(0xFF3366FF),
    'ali' => const Color(0xFF6E56CF),
    _ => AppleColors.systemBlue,
  };

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final cardBg = isDark ? const Color(0xFF232328) : Colors.white;
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);
    final effectiveLabels = widget.storage.effectiveDriveOrder
        .map(StorageService.driveShortLabelZh)
        .join(' > ');

    return ListView(
      key: const ValueKey('ios-drive-priority-sheet'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        // 1. Default playback source mode
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '默认播放来源',
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cardBorder, width: 0.65),
          ),
          child: Column(
            children: [
              for (int i = 0;
                  i < PlaybackSourcePriorityMode.values.length;
                  i++) ...[
                if (i > 0)
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 48,
                    color: cardBorder,
                  ),
                _buildModeOptionTile(
                  PlaybackSourcePriorityMode.values[i],
                  palette: palette,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),

        // 2. Quick one-tap primary netdisk selector
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '快速选择首选网盘（点击直接置顶为默认）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final key in StorageService.defaultDriveOrder)
              _buildQuickDefaultChip(
                key,
                isPrimary: _order.isNotEmpty &&
                    _order.first == key &&
                    _mode == PlaybackSourcePriorityMode.netdiskFirst,
                isLoggedIn: widget.storage.isNetdiskLoggedIn(key),
                palette: palette,
              ),
          ],
        ),
        const SizedBox(height: 18),

        // 3. Manual drag-and-drop & up/down reorderable list
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '网盘优先顺序（按住右侧手柄拖拽或点箭头调整）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('drive-priority-reset-btn'),
                onTap: _resetDefaultOrder,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '恢复默认',
                    style: TextStyle(
                      color: AppleColors.systemBlue,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cardBorder, width: 0.65),
            ),
            child: ReorderableListView.builder(
              key: const ValueKey('drive-priority-reorderable-list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _order.length,
              onReorder: _onReorder,
              proxyDecorator: (child, index, animation) {
                return Material(
                  color: Colors.transparent,
                  elevation: 8,
                  shadowColor: Colors.black45,
                  borderRadius: BorderRadius.circular(14),
                  child: child,
                );
              },
              itemBuilder: (ctx, index) {
                final key = _order[index];
                return _buildReorderableDriveRow(
                  key: ValueKey('drive-priority-row-$key'),
                  driveKey: key,
                  index: index,
                  total: _order.length,
                  palette: palette,
                  cardBorder: cardBorder,
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '当前实际匹配顺序：$effectiveLabels',
            key: const ValueKey('drive-priority-effective-summary'),
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 4. Smart logged-in preference switch
        IosSettingsGroup(
          footer:
              '开启后，已扫码登录的网盘会自动排在未登录网盘前面，同时在各自组内严格保留您上面编辑的先后顺序。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('drive-priority-logged-first-switch'),
              icon: CupertinoIcons.checkmark_shield_fill,
              iconColor: AppleColors.systemGreen,
              title: '已登录网盘自动排在前面',
              value: _prioritizeLoggedIn,
              onChanged: _togglePrioritizeLoggedIn,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModeOptionTile(
    PlaybackSourcePriorityMode option, {
    required ApplePalette palette,
  }) {
    final selected = _mode == option;
    return InkWell(
      key: ValueKey('playback-source-mode-${option.qualityValue}'),
      onTap: () => _selectMode(option),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: selected
                    ? AppleColors.systemBlue
                    : palette.labelTertiary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                option.icon,
                size: 16,
                color: selected ? Colors.white : palette.labelSecondary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.titleZh,
                    style: TextStyle(
                      color: palette.labelPrimary,
                      fontSize: 14.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.subtitleZh,
                    style: TextStyle(
                      color: palette.labelSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 20,
              color: selected
                  ? AppleColors.systemBlue
                  : palette.labelTertiary.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickDefaultChip(
    String driveKey, {
    required bool isPrimary,
    required bool isLoggedIn,
    required ApplePalette palette,
  }) {
    final label = StorageService.driveShortLabelZh(driveKey);
    final accent = _driveAccentColor(driveKey);
    return GestureDetector(
      key: ValueKey('drive-quick-default-$driveKey'),
      onTap: () => _promoteDriveToTop(driveKey),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isPrimary
              ? accent.withValues(alpha: palette.isDark ? 0.28 : 0.14)
              : (palette.isDark
                    ? const Color(0xFF26262C)
                    : const Color(0xFFF2F2F7)),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isPrimary
                ? accent.withValues(alpha: 0.75)
                : (palette.isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.08)),
            width: isPrimary ? 1.1 : 0.65,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLoggedIn
                    ? AppleColors.systemGreen
                    : palette.labelTertiary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              isPrimary ? '$label · 默认首选' : label,
              style: TextStyle(
                color: isPrimary
                    ? (palette.isDark ? Colors.white : accent)
                    : palette.labelPrimary,
                fontSize: 13,
                fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReorderableDriveRow({
    required Key key,
    required String driveKey,
    required int index,
    required int total,
    required ApplePalette palette,
    required Color cardBorder,
  }) {
    final spec = _specFor(driveKey);
    final loggedIn = widget.storage.isNetdiskLoggedIn(driveKey);
    final accent = _driveAccentColor(driveKey);
    final isFirst = index == 0;
    final isLast = index == total - 1;

    return Container(
      key: key,
      decoration: BoxDecoration(
        border: index < total - 1
            ? Border(bottom: BorderSide(color: cardBorder, width: 0.5))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isFirst
                  ? accent
                  : accent.withValues(alpha: palette.isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: isFirst
                    ? Colors.white
                    : (palette.isDark ? Colors.white : accent),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        spec.providerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: loggedIn
                            ? AppleColors.systemGreen.withValues(alpha: 0.16)
                            : palette.labelTertiary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        loggedIn ? '已登录' : '未登录',
                        style: TextStyle(
                          color: loggedIn
                              ? AppleColors.systemGreen
                              : palette.labelSecondary,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '匹配线路：${spec.lineBadges.join(" / ")}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (!isFirst)
            TextButton(
              key: ValueKey('drive-make-top-$driveKey'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _promoteDriveToTop(driveKey),
              child: const Text(
                '置顶',
                style: TextStyle(
                  color: AppleColors.systemBlue,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          IconButton(
            key: ValueKey('drive-move-up-$driveKey'),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            icon: Icon(
              CupertinoIcons.chevron_up,
              size: 16,
              color: isFirst ? palette.labelTertiary : palette.labelPrimary,
            ),
            onPressed: isFirst ? null : () => _moveDrive(index, -1),
          ),
          IconButton(
            key: ValueKey('drive-move-down-$driveKey'),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            icon: Icon(
              CupertinoIcons.chevron_down,
              size: 16,
              color: isLast ? palette.labelTertiary : palette.labelPrimary,
            ),
            onPressed: isLast ? null : () => _moveDrive(index, 1),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              key: ValueKey('drive-drag-handle-$driveKey'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Icon(
                CupertinoIcons.line_horizontal_3,
                size: 18,
                color: palette.labelSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

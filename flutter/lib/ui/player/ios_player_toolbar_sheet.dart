// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show Colors, Material, MaterialType, ReorderableDragStartListener, ReorderableListView;
import 'package:flutter/services.dart';

import '../../core/storage_service.dart';
import '../apple_theme.dart';

/// Metadata descriptor for each customizable iOS player toolbar button.
class IosPlayerToolbarItemMeta {
  final String id;
  final String titleZh;
  final String subtitleZh;
  final IconData icon;
  final bool lockedRequired;

  const IosPlayerToolbarItemMeta({
    required this.id,
    required this.titleZh,
    required this.subtitleZh,
    required this.icon,
    this.lockedRequired = false,
  });

  static const Map<String, IosPlayerToolbarItemMeta> catalog =
      <String, IosPlayerToolbarItemMeta>{
    'episodes': IosPlayerToolbarItemMeta(
      id: 'episodes',
      titleZh: '选集 / 版本',
      subtitleZh: '剧集选集或电影多清晰度版本切换',
      icon: CupertinoIcons.square_grid_2x2_fill,
    ),
    'lines': IosPlayerToolbarItemMeta(
      id: 'lines',
      titleZh: '线路',
      subtitleZh: '切换不同站点或网盘播放线路',
      icon: CupertinoIcons.layers_alt_fill,
    ),
    'speed': IosPlayerToolbarItemMeta(
      id: 'speed',
      titleZh: '倍速',
      subtitleZh: '0.5× – 3.0× 播放倍速调节',
      icon: CupertinoIcons.speedometer,
    ),
    'danmu_subtitle': IosPlayerToolbarItemMeta(
      id: 'danmu_subtitle',
      titleZh: '弹幕/字幕',
      subtitleZh: '弹幕开关（默认关闭）、弹幕设置与内封/AI双语字幕',
      icon: CupertinoIcons.captions_bubble_fill,
    ),
    'aspect': IosPlayerToolbarItemMeta(
      id: 'aspect',
      titleZh: '画面',
      subtitleZh: '画面铺满、裁切比例与播放偏好',
      icon: CupertinoIcons.slider_horizontal_3,
    ),
    'engine': IosPlayerToolbarItemMeta(
      id: 'engine',
      titleZh: '播放器',
      subtitleZh: '切换 AVPlayer / MDK (Metal 4K 杜比) / MPV 内核',
      icon: CupertinoIcons.play_rectangle_fill,
    ),
    'audio': IosPlayerToolbarItemMeta(
      id: 'audio',
      titleZh: '音轨',
      subtitleZh: '切换国语、粤语、原声或多声道杜比音轨',
      icon: CupertinoIcons.speaker_2_fill,
    ),
    'skip_intro_outro': IosPlayerToolbarItemMeta(
      id: 'skip_intro_outro',
      titleZh: '片头片尾',
      subtitleZh: '快捷标记或微调跳过片头与片尾时长',
      icon: CupertinoIcons.forward_end_alt_fill,
    ),
    'fullscreen': IosPlayerToolbarItemMeta(
      id: 'fullscreen',
      titleZh: '全屏 / 竖屏',
      subtitleZh: '横竖屏切换按钮',
      icon: CupertinoIcons.fullscreen,
    ),
    'loudness': IosPlayerToolbarItemMeta(
      id: 'loudness',
      titleZh: '人声响度',
      subtitleZh: '夜间防炸耳与对白增强开关',
      icon: CupertinoIcons.waveform_path_ecg,
    ),
    'anime4k': IosPlayerToolbarItemMeta(
      id: 'anime4k',
      titleZh: '超分画质',
      subtitleZh: 'Anime4K 实时超分着色器档位',
      icon: CupertinoIcons.wand_stars,
    ),
    'sleep_timer': IosPlayerToolbarItemMeta(
      id: 'sleep_timer',
      titleZh: '定时关闭',
      subtitleZh: '播完本集或倒计时自动暂停',
      icon: CupertinoIcons.moon_zzz_fill,
    ),
    'pip': IosPlayerToolbarItemMeta(
      id: 'pip',
      titleZh: '画中画',
      subtitleZh: '一键悬浮小窗播放',
      icon: CupertinoIcons.rectangle_on_rectangle,
    ),
    'more': IosPlayerToolbarItemMeta(
      id: 'more',
      titleZh: '更多',
      subtitleZh: '完整播放设置与工具栏自定义入口（常驻保留）',
      icon: CupertinoIcons.ellipsis_circle_fill,
      lockedRequired: true,
    ),
  };

  static IosPlayerToolbarItemMeta of(String id) {
    return catalog[id] ??
        IosPlayerToolbarItemMeta(
          id: id,
          titleZh: id,
          subtitleZh: '',
          icon: CupertinoIcons.circle,
        );
  }
}

/// Shows an Apple-style sheet allowing the user to add, remove, and manually
/// reorder buttons in the iOS player bottom toolbar.
Future<List<String>?> showIosPlayerToolbarCustomizeSheet(
  BuildContext context, {
  required StorageService storage,
  ValueChanged<List<String>>? onChanged,
}) {
  return showIos27LiquidSheet<List<String>>(
    context: context,
    title: '自定义播放器工具栏',
    maxWidth: 500,
    builder: (ctx) => IosPlayerToolbarCustomizer(
      storage: storage,
      onChanged: onChanged,
    ),
  );
}

class IosPlayerToolbarCustomizer extends StatefulWidget {
  final StorageService storage;
  final ValueChanged<List<String>>? onChanged;

  const IosPlayerToolbarCustomizer({
    super.key,
    required this.storage,
    this.onChanged,
  });

  @override
  State<IosPlayerToolbarCustomizer> createState() =>
      _IosPlayerToolbarCustomizerState();
}

class _IosPlayerToolbarCustomizerState
    extends State<IosPlayerToolbarCustomizer> {
  late List<String> _enabledIds;

  @override
  void initState() {
    super.initState();
    _enabledIds = List<String>.of(widget.storage.iosPlayerToolbarItems);
  }

  List<String> get _availableToAdd {
    final activeSet = _enabledIds.toSet();
    return StorageService.allIosPlayerToolbarItems
        .where((id) => !activeSet.contains(id))
        .toList(growable: false);
  }

  Future<void> _save(List<String> next) async {
    final normalized = StorageService.normalizeIosPlayerToolbarItems(next);
    setState(() => _enabledIds = List<String>.of(normalized));
    await widget.storage.setIosPlayerToolbarItems(normalized);
    widget.onChanged?.call(normalized);
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    HapticFeedback.selectionClick();
    final copy = List<String>.of(_enabledIds);
    final moved = copy.removeAt(oldIndex);
    copy.insert(newIndex, moved);
    unawaited(_save(copy));
  }

  void _moveBy(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _enabledIds.length) return;
    HapticFeedback.selectionClick();
    final copy = List<String>.of(_enabledIds);
    final moved = copy.removeAt(index);
    copy.insert(target, moved);
    unawaited(_save(copy));
  }

  void _removeAt(int index) {
    final id = _enabledIds[index];
    if (IosPlayerToolbarItemMeta.of(id).lockedRequired) return;
    if (_enabledIds.length <= 2) return;
    HapticFeedback.selectionClick();
    final copy = List<String>.of(_enabledIds)..removeAt(index);
    unawaited(_save(copy));
  }

  void _addItem(String id) {
    if (_enabledIds.contains(id)) return;
    HapticFeedback.selectionClick();
    final copy = List<String>.of(_enabledIds);
    final moreIdx = copy.indexOf('more');
    if (moreIdx >= 0) {
      copy.insert(moreIdx, id);
    } else {
      copy.add(id);
    }
    unawaited(_save(copy));
  }

  Future<void> _resetDefaults() async {
    HapticFeedback.mediumImpact();
    await widget.storage.resetIosPlayerToolbarItems();
    final defaults = StorageService.defaultIosPlayerToolbarItems;
    if (mounted) {
      setState(() => _enabledIds = List<String>.of(defaults));
    }
    widget.onChanged?.call(defaults);
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF25252B) : const Color(0xFFF3F4F8);
    final addable = _availableToAdd;

    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        key: const ValueKey('ios-player-toolbar-customizer'),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已启用按钮（${_enabledIds.length} 项 · 拖拽或上下微调顺序）',
                    style: TextStyle(
                      color: p.labelSecondary,
                      fontSize: 12.8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('ios-toolbar-reset-btn'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: const Size(0, 26),
                  onPressed: _resetDefaults,
                  child: Text(
                    '恢复默认',
                    style: TextStyle(
                      color: p.systemBlue,
                      fontSize: 12.8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(15),
              ),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _enabledIds.length,
                onReorder: _onReorder,
                itemBuilder: (ctx, idx) {
                  final id = _enabledIds[idx];
                  final meta = IosPlayerToolbarItemMeta.of(id);
                  return Container(
                    key: ValueKey('toolbar-active-$id'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      border: idx == _enabledIds.length - 1
                          ? null
                          : Border(
                              bottom: BorderSide(
                                color: p.isDark
                                    ? const Color(0x18FFFFFF)
                                    : const Color(0x12000000),
                                width: 0.5,
                              ),
                            ),
                    ),
                    child: Row(
                      children: [
                        GestureDetector(
                          key: ValueKey('toolbar-remove-$id'),
                          behavior: HitTestBehavior.opaque,
                          onTap: meta.lockedRequired
                              ? null
                              : () => _removeAt(idx),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Icon(
                              meta.lockedRequired
                                  ? CupertinoIcons.lock_fill
                                  : CupertinoIcons.minus_circle_fill,
                              size: 20,
                              color: meta.lockedRequired
                                  ? p.labelTertiary
                                  : AppleColors.systemRed,
                            ),
                          ),
                        ),
                        Icon(meta.icon, size: 17, color: p.systemBlue),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta.titleZh,
                                style: TextStyle(
                                  color: p.labelPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (meta.subtitleZh.isNotEmpty)
                                Text(
                                  meta.subtitleZh,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.labelSecondary,
                                    fontSize: 11.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        CupertinoButton(
                          key: ValueKey('toolbar-up-$id'),
                          padding: const EdgeInsets.all(4),
                          minimumSize: const Size(28, 28),
                          onPressed: idx > 0 ? () => _moveBy(idx, -1) : null,
                          child: Icon(
                            CupertinoIcons.chevron_up,
                            size: 15,
                            color: idx > 0 ? p.labelSecondary : p.labelTertiary,
                          ),
                        ),
                        CupertinoButton(
                          key: ValueKey('toolbar-down-$id'),
                          padding: const EdgeInsets.all(4),
                          minimumSize: const Size(28, 28),
                          onPressed: idx < _enabledIds.length - 1
                              ? () => _moveBy(idx, 1)
                              : null,
                          child: Icon(
                            CupertinoIcons.chevron_down,
                            size: 15,
                            color: idx < _enabledIds.length - 1
                                ? p.labelSecondary
                                : p.labelTertiary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        ReorderableDragStartListener(
                          index: idx,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            child: Icon(
                              CupertinoIcons.line_horizontal_3,
                              size: 18,
                              color: p.labelSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (addable.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '可添加到工具栏的按钮',
                style: TextStyle(
                  color: p.labelSecondary,
                  fontSize: 12.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Column(
                  children: [
                    for (int i = 0; i < addable.length; i++)
                      GestureDetector(
                        key: ValueKey('toolbar-add-${addable[i]}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _addItem(addable[i]),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: i == addable.length - 1
                                ? null
                                : Border(
                                    bottom: BorderSide(
                                      color: p.isDark
                                          ? const Color(0x18FFFFFF)
                                          : const Color(0x12000000),
                                      width: 0.5,
                                    ),
                                  ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.plus_circle_fill,
                                size: 20,
                                color: AppleColors.systemGreen,
                              ),
                              const SizedBox(width: 10),
                              Icon(
                                IosPlayerToolbarItemMeta.of(addable[i]).icon,
                                size: 17,
                                color: p.systemBlue,
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      IosPlayerToolbarItemMeta.of(addable[i])
                                          .titleZh,
                                      style: TextStyle(
                                        color: p.labelPrimary,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      IosPlayerToolbarItemMeta.of(addable[i])
                                          .subtitleZh,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.labelSecondary,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

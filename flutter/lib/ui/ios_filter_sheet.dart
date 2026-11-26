import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'motion/ios27_springs.dart';
import 'motion/motion_tokens.dart';

/// Computes the responsive equal-width column count for the iOS catalog filter
/// option grid so narrow iPhones, large Dynamic Type scales, and iPad Split
/// View narrow panes automatically reduce columns without horizontal clipping.
int computeIosFilterColumnCount({
  required double availableWidth,
  required double textScale,
}) {
  final safeScale = math.max(1.0, textScale);
  final effectiveWidth = availableWidth / safeScale;
  if (availableWidth < 250 || effectiveWidth < 205) return 1;
  if (availableWidth < 340 || effectiveWidth < 275) return 2;
  if (effectiveWidth < 460) return 3;
  return 4;
}

/// Formats the active draft filter summary line (e.g. `动作 · 日本 · 2024`).
String formatIosFilterSummary({
  required List<IosNativeFilterCategory> categories,
  required String selectedCategoryId,
  required String selectedGenreLabel,
  required String selectedArea,
  required String selectedYear,
}) {
  final parts = <String>[];
  if (selectedCategoryId.isNotEmpty) {
    final matched = categories.where(
      (c) => c.kind == 'cat' && c.id == selectedCategoryId,
    );
    parts.add(matched.isNotEmpty ? matched.first.label : selectedCategoryId);
  } else if (selectedGenreLabel.isNotEmpty) {
    parts.add(selectedGenreLabel);
  }
  if (selectedArea.isNotEmpty) {
    parts.add(selectedArea);
  }
  if (selectedYear.isNotEmpty) {
    parts.add(selectedYear);
  }
  return parts.isEmpty ? '全部' : parts.join(' · ');
}

/// Presents the redesigned iOS catalog filter modal sheet (iOS 14–25 Flutter
/// fallback path matching the iOS 26+ native `MarcoNativeFilterSheetController`).
///
/// Returns an [IosNativeFilterResult] only when the user taps `应用`; closing
/// via `×`, barrier tap, or pull-down returns `null` so the caller leaves the
/// listing and scroll offset untouched.
Future<IosNativeFilterResult?> showIosCatalogFilterSheet({
  required BuildContext context,
  String title = '片库筛选',
  required List<IosNativeFilterCategory> categories,
  required String selectedCategoryId,
  required String selectedGenreLabel,
  required List<String> areas,
  required String selectedArea,
  required List<String> years,
  required String selectedYear,
}) async {
  activeAppleModalSheetCount.value++;
  try {
    return await showModalBottomSheet<IosNativeFilterResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      builder: (sheetCtx) {
        return IosCatalogFilterSheetBody(
          title: title,
          categories: categories,
          initialCategoryId: selectedCategoryId,
          initialGenreLabel: selectedGenreLabel,
          areas: areas,
          initialArea: selectedArea,
          years: years,
          initialYear: selectedYear,
        );
      },
    );
  } finally {
    activeAppleModalSheetCount.value = math.max(
      0,
      activeAppleModalSheetCount.value - 1,
    );
  }
}

class IosCatalogFilterSheetBody extends StatefulWidget {
  const IosCatalogFilterSheetBody({
    super.key,
    required this.title,
    required this.categories,
    required this.initialCategoryId,
    required this.initialGenreLabel,
    required this.areas,
    required this.initialArea,
    required this.years,
    required this.initialYear,
  });

  final String title;
  final List<IosNativeFilterCategory> categories;
  final String initialCategoryId;
  final String initialGenreLabel;
  final List<String> areas;
  final String initialArea;
  final List<String> years;
  final String initialYear;

  @override
  State<IosCatalogFilterSheetBody> createState() =>
      _IosCatalogFilterSheetBodyState();
}

class _IosCatalogFilterSheetBodyState extends State<IosCatalogFilterSheetBody> {
  static const List<String> _dimensionTitles = <String>['类别', '地区', '年份'];

  int _activeDimension = 0;
  late String _draftCategoryId;
  late String _draftGenreLabel;
  late String _draftArea;
  late String _draftYear;

  @override
  void initState() {
    super.initState();
    _draftCategoryId = widget.initialCategoryId;
    _draftGenreLabel = widget.initialGenreLabel;
    _draftArea = widget.initialArea;
    _draftYear = widget.initialYear;
  }

  bool get _hasDraftSelection =>
      _draftCategoryId.isNotEmpty ||
      _draftGenreLabel.isNotEmpty ||
      _draftArea.isNotEmpty ||
      _draftYear.isNotEmpty;

  String get _summaryText => formatIosFilterSummary(
        categories: widget.categories,
        selectedCategoryId: _draftCategoryId,
        selectedGenreLabel: _draftGenreLabel,
        selectedArea: _draftArea,
        selectedYear: _draftYear,
      );

  bool _isDimensionSelected(int dim) => switch (dim) {
        0 => _draftCategoryId.isNotEmpty || _draftGenreLabel.isNotEmpty,
        1 => _draftArea.isNotEmpty,
        _ => _draftYear.isNotEmpty,
      };

  String _dimensionSelectedLabel(int dim) {
    switch (dim) {
      case 0:
        if (_draftCategoryId.isNotEmpty) {
          final matched = widget.categories.where(
            (c) => c.kind == 'cat' && c.id == _draftCategoryId,
          );
          return matched.isNotEmpty ? matched.first.label : _draftCategoryId;
        }
        return _draftGenreLabel;
      case 1:
        return _draftArea;
      default:
        return _draftYear;
    }
  }

  void _selectCategory(IosNativeFilterCategory choice) {
    HapticFeedback.selectionClick();
    setState(() {
      switch (choice.kind) {
        case 'all':
          _draftCategoryId = '';
          _draftGenreLabel = '';
        case 'cat':
          _draftCategoryId = choice.id;
          _draftGenreLabel = '';
        default:
          _draftCategoryId = '';
          _draftGenreLabel = choice.label;
      }
    });
  }

  void _selectArea(String area) {
    HapticFeedback.selectionClick();
    setState(() {
      _draftArea = area == '全部' ? '' : area;
    });
  }

  void _selectYear(String year) {
    HapticFeedback.selectionClick();
    setState(() {
      _draftYear = year == '全部' ? '' : year;
    });
  }

  void _resetDraft() {
    HapticFeedback.lightImpact();
    setState(() {
      _draftCategoryId = '';
      _draftGenreLabel = '';
      _draftArea = '';
      _draftYear = '';
    });
  }

  void _applyDraft() {
    Navigator.of(context).pop(
      IosNativeFilterResult(
        categoryId: _draftCategoryId,
        genreLabel: _draftGenreLabel,
        area: _draftArea,
        year: _draftYear,
      ),
    );
  }

  void _cancel() {
    Navigator.of(context).pop(null);
  }

  List<_FilterOptionItem> _activeOptions() {
    switch (_activeDimension) {
      case 0:
        return [
          for (final c in widget.categories)
            _FilterOptionItem(
              keyValue: 'cat:${c.kind}:${c.id}:${c.label}',
              label: c.label,
              selected: switch (c.kind) {
                'all' => _draftCategoryId.isEmpty && _draftGenreLabel.isEmpty,
                'cat' => _draftCategoryId == c.id,
                _ => _draftCategoryId.isEmpty && _draftGenreLabel == c.label,
              },
              onTap: () => _selectCategory(c),
            ),
        ];
      case 1:
        return [
          for (final a in widget.areas)
            _FilterOptionItem(
              keyValue: 'area:$a',
              label: a,
              selected: (_draftArea.isEmpty && a == '全部') || _draftArea == a,
              onTap: () => _selectArea(a),
            ),
        ];
      default:
        return [
          for (final y in widget.years)
            _FilterOptionItem(
              keyValue: 'year:$y',
              label: y,
              selected: (_draftYear.isEmpty && y == '全部') || _draftYear == y,
              onTap: () => _selectYear(y),
            ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = ApplePalette.isDarkOf(context);
    final media = MediaQuery.of(context);
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final maxSheetHeight = math.min(media.size.height * 0.82, 640.0);
    final textScale = media.textScaler.scale(14.0) / 14.0;
    final options = _activeOptions();
    final sheetBg = isDark
        ? const Color(0xFF16161A)
        : const Color(0xFFF6F6FA);
    final hairline = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: maxSheetHeight,
        ),
        child: Material(
          key: const ValueKey('ios-catalog-filter-sheet'),
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Grabber handle for swipe-down dismissal affordance
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.24)
                          : Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
              // Top bar: ONLY title ("片库筛选") + Close button ("×")
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 10, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        key: const ValueKey('ios-filter-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: '关闭',
                      child: GestureDetector(
                        key: const ValueKey('ios-filter-close-button'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _cancel,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          child: Center(
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.black.withValues(alpha: 0.07),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                CupertinoIcons.xmark,
                                size: 15,
                                color: palette.labelSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Three-dimension switcher: 类别 | 地区 | 年份
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Container(
                  key: const ValueKey('ios-filter-dimension-tabs'),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < _dimensionTitles.length; i++)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: _activeDimension == i,
                            label: _isDimensionSelected(i)
                                ? '${_dimensionTitles[i]}，已选${_dimensionSelectedLabel(i)}'
                                : _dimensionTitles[i],
                            child: GestureDetector(
                              key: ValueKey('ios-filter-dim-$i'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (_activeDimension == i) return;
                                HapticFeedback.selectionClick();
                                setState(() => _activeDimension = i);
                              },
                              child: AnimatedContainer(
                                duration: reduceMotion
                                    ? MotionTokens.durationReducedHudFade
                                    : MotionTokens.durationFast,
                                curve: reduceMotion
                                    ? Curves.linear
                                    : Ios27Spring.snappy.curve,
                                constraints: const BoxConstraints(minHeight: 42),
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _activeDimension == i
                                      ? (isDark
                                          ? const Color(0xFF2C2C32)
                                          : Colors.white)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(9.5),
                                  boxShadow: _activeDimension == i
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: isDark ? 0.28 : 0.08,
                                            ),
                                            blurRadius: 6,
                                            offset: const Offset(0, 1.5),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _dimensionTitles[i],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: _activeDimension == i
                                              ? palette.labelPrimary
                                              : palette.labelSecondary,
                                          fontSize: 13.5,
                                          fontWeight: _activeDimension == i
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (_isDimensionSelected(i)) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        key: ValueKey('ios-filter-dim-dot-$i'),
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: AppleColors.systemBlue,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Always-visible selected summary row (allows 2 lines at large Dynamic Type)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _hasDraftSelection
                        ? AppleColors.systemBlue.withValues(
                            alpha: isDark ? 0.16 : 0.09,
                          )
                        : (isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已选：',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _summaryText,
                          key: const ValueKey('ios-filter-summary'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _hasDraftSelection
                                ? AppleColors.systemBlue
                                : palette.labelSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(height: 0.5, color: hairline),
              // Active dimension options in an equal-width left-aligned grid
              Flexible(
                child: SingleChildScrollView(
                  key: ValueKey('ios-filter-options-scroll-$_activeDimension'),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = computeIosFilterColumnCount(
                        availableWidth: constraints.maxWidth,
                        textScale: textScale,
                      );
                      const spacing = 10.0;
                      final rowCount = (options.length / cols).ceil();
                      return Column(
                        key: ValueKey('ios-filter-grid-cols-$cols'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var row = 0; row < rowCount; row++) ...[
                            if (row > 0) const SizedBox(height: spacing),
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var col = 0; col < cols; col++) ...[
                                    if (col > 0) const SizedBox(width: spacing),
                                    Expanded(
                                      child: (row * cols + col) < options.length
                                          ? _FilterOptionTile(
                                              item: options[row * cols + col],
                                            )
                                          : const SizedBox.shrink(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
              Container(height: 0.5, color: hairline),
              // Bottom fixed bar: 重置 + 应用
              SafeArea(
                top: false,
                child: Padding(
                  key: const ValueKey('ios-filter-bottom-bar'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: Semantics(
                          button: true,
                          enabled: _hasDraftSelection,
                          label: '重置',
                          child: GestureDetector(
                            key: const ValueKey('ios-filter-reset-button'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _hasDraftSelection ? _resetDraft : null,
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 46),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(
                                        alpha: _hasDraftSelection ? 0.12 : 0.05,
                                      )
                                    : Colors.black.withValues(
                                        alpha: _hasDraftSelection ? 0.07 : 0.03,
                                      ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '重置',
                                style: TextStyle(
                                  color: _hasDraftSelection
                                      ? palette.labelPrimary
                                      : palette.labelTertiary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 6,
                        child: Semantics(
                          button: true,
                          label: '应用',
                          child: GestureDetector(
                            key: const ValueKey('ios-filter-apply-button'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _applyDraft,
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 46),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppleColors.systemBlue,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Text(
                                '应用',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
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
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterOptionItem {
  const _FilterOptionItem({
    required this.keyValue,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String keyValue;
  final String label;
  final bool selected;
  final VoidCallback onTap;
}

class _FilterOptionTile extends StatelessWidget {
  const _FilterOptionTile({required this.item});

  final _FilterOptionItem item;

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = ApplePalette.isDarkOf(context);
    final selected = item.selected;

    final fillColor = selected
        ? AppleColors.systemBlue
        : (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white);
    final borderColor = selected
        ? AppleColors.systemBlue
        : (isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.08));
    final textColor = selected ? Colors.white : palette.labelPrimary;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        key: ValueKey('ios-filter-option-${item.keyValue}'),
        behavior: HitTestBehavior.opaque,
        onTap: item.onTap,
        child: AnimatedContainer(
          duration: Ios27ConcentricGeometry.isReduceMotion(context)
              ? MotionTokens.durationReducedHudFade
              : MotionTokens.durationFast,
          curve: Ios27ConcentricGeometry.isReduceMotion(context)
              ? Curves.linear
              : Ios27Spring.snappy.curve,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: selected ? 1.0 : 0.6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  item.label,
                  textAlign: TextAlign.left,
                  softWrap: true,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13.5,
                    height: 1.25,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                const Icon(
                  CupertinoIcons.checkmark,
                  size: 14,
                  color: Colors.white,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

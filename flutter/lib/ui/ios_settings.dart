import 'windows_appearance.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Material, MaterialType;
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';

class SettingsPane {
  final String id, title, subtitle;
  final String? trailingText;
  final String sectionGroup;
  final IconData icon;
  final Color color;
  final List<SettingsPane> children;
  final Widget? content;
  const SettingsPane(
    this.id,
    this.title,
    this.subtitle,
    this.icon,
    this.color, {
    this.trailingText,
    this.sectionGroup = 'default',
    this.children = const [],
    this.content,
  });
}

typedef SettingsPanes = List<SettingsPane> Function(VoidCallback refresh);

/// Level-1 iOS Settings tab styled after native iOS System Settings (`UITableViewStyleInsetGrouped`).
/// Version information lives inside the `关于与更新` secondary page rather than on the root header,
/// and tapping any category pushes a full-screen `CupertinoPageRoute` secondary page.
class IosSettingsPage extends StatefulWidget {
  final SettingsPanes pages;
  final VoidCallback onChanged;
  final String version;
  const IosSettingsPage({
    super.key,
    required this.pages,
    required this.onChanged,
    this.version = '',
  });

  @override
  State<IosSettingsPage> createState() => _IosSettingsPageState();
}

class _IosSettingsPageState extends State<IosSettingsPage> {
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showCompactNavBar = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final next = _scrollController.offset > 52;
    if (next != _showCompactNavBar && mounted) {
      setState(() => _showCompactNavBar = next);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _searchController.dispose();
    _revision.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    _revision.value++;
    if (mounted) setState(() {});
    widget.onChanged();
  }

  void _openPanePath(
    BuildContext context,
    List<String> pathIds, {
    String parentTitle = '设置',
  }) {
    Navigator.of(context)
        .push<void>(
          buildApplePageRoute<void>(
            builder: (_) => IosSettingsSubPage(
              pages: widget.pages,
              pathIds: pathIds,
              parentTitle: parentTitle,
              revision: _revision,
              onChanged: _notifyChanged,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  void _openRootPane(BuildContext context, SettingsPane entry) {
    _openPanePath(context, [entry.id], parentTitle: '设置');
  }

  List<List<SettingsPane>> _groupEntries(List<SettingsPane> entries) {
    final groups = <List<SettingsPane>>[];
    for (final entry in entries) {
      if (groups.isEmpty ||
          groups.last.first.sectionGroup != entry.sectionGroup) {
        groups.add([entry]);
      } else {
        groups.last.add(entry);
      }
    }
    return groups;
  }

  String? _sectionHeaderFor(String group) => switch (group) {
    'core' => '偏好与视听体验',
    'account' => '片源、扩展与数据',
    'about' => '应用信息',
    _ => null,
  };

  List<({SettingsPane pane, List<String> pathIds, String breadcrumb})>
  _searchMatches(List<SettingsPane> roots, String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits =
        <({SettingsPane pane, List<String> pathIds, String breadcrumb})>[];
    for (final root in roots) {
      final rootMatch =
          root.title.toLowerCase().contains(q) ||
          root.subtitle.toLowerCase().contains(q) ||
          (root.trailingText?.toLowerCase().contains(q) ?? false);
      if (rootMatch) {
        hits.add((pane: root, pathIds: [root.id], breadcrumb: root.subtitle));
      }
      for (final child in root.children) {
        final childMatch =
            child.title.toLowerCase().contains(q) ||
            child.subtitle.toLowerCase().contains(q) ||
            (child.trailingText?.toLowerCase().contains(q) ?? false);
        if (childMatch) {
          hits.add((
            pane: child,
            pathIds: [root.id, child.id],
            breadcrumb: '${root.title} · ${child.subtitle}',
          ));
        }
      }
    }
    return hits;
  }

  Widget _buildIos26SearchPill() {
    return Container(
      key: const ValueKey('ios-settings-search'),
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xEB1C1C1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0x1EFFFFFF),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.search,
            color: Color(0x99EBEBF5),
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CupertinoTextField(
              controller: _searchController,
              placeholder: '搜索设置',
              placeholderStyle: const TextStyle(
                color: Color(0x8CEBEBF5),
                fontSize: 15,
              ),
              style: const TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 15,
              ),
              padding: EdgeInsets.zero,
              decoration: null,
              clearButtonMode: OverlayVisibilityMode.never,
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(
                  CupertinoIcons.clear_circled_solid,
                  color: Color(0x99EBEBF5),
                  size: 17,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final safeBottom = mediaPadding.bottom;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 600;
    final hPad = isWide ? 24.0 : 16.0;
    final groupGap = isWide ? 22.0 : 16.0;
    final entries = widget.pages(_notifyChanged);
    final grouped = _groupEntries(entries);
    final query = _searchQuery.trim();
    final searchHits = query.isNotEmpty
        ? _searchMatches(entries, query)
        : const <
            ({SettingsPane pane, List<String> pathIds, String breadcrumb})
          >[];

    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: ListView(
            key: const ValueKey('ios-settings-root'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(hPad, 6, hPad, safeBottom + 108),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 740),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 2, 4, 8),
                        child: Text(
                          '设置',
                          style: TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                            height: 1.15,
                          ),
                        ),
                      ),
                      _buildIos26SearchPill(),
                      const SizedBox(height: 14),
                      if (query.isNotEmpty) ...[
                        if (searchHits.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 36),
                            child: Center(
                              child: Text(
                                '未找到匹配的设置项',
                                style: TextStyle(
                                  color: Color(0x8CEBEBF5),
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          )
                        else
                          IosSettingsGroup(
                            header: '搜索结果 (${searchHits.length})',
                            children: [
                              for (final hit in searchHits)
                                IosSettingsRow(
                                  icon: hit.pane.icon,
                                  iconColor: hit.pane.color,
                                  title: hit.pane.title,
                                  subtitle: hit.breadcrumb.isNotEmpty
                                      ? hit.breadcrumb
                                      : null,
                                  subtitleMaxLines: 1,
                                  trailingText: hit.pane.trailingText,
                                  showChevron: true,
                                  onTap: () => _openPanePath(
                                    context,
                                    hit.pathIds,
                                    parentTitle: '设置',
                                  ),
                                ),
                            ],
                          ),
                      ] else ...[
                        for (var gIdx = 0; gIdx < grouped.length; gIdx++) ...[
                          if (gIdx > 0) SizedBox(height: groupGap),
                          IosSettingsGroup(
                            header: _sectionHeaderFor(
                              grouped[gIdx].first.sectionGroup,
                            ),
                            children: [
                              for (final entry in grouped[gIdx])
                                IosSettingsRow(
                                  key: ValueKey(
                                    'settings-category-${entry.id}',
                                  ),
                                  icon: entry.icon,
                                  iconColor: entry.color,
                                  title: entry.title,
                                  trailingText: entry.trailingText,
                                  compact: true,
                                  showChevron: true,
                                  onTap: () => _openRootPane(context, entry),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Sticky collapsing inline iOS 26 navigation title bar when scrolled in portrait.
        if (MediaQuery.sizeOf(context).height >= 500)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: true,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                opacity: _showCompactNavBar ? 1.0 : 0.0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0xEB0A0A0D),
                    border: Border(
                      bottom: BorderSide(
                        color: Color(0x2EFFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(top: mediaPadding.top),
                    child: const SizedBox(
                      height: 44,
                      child: Center(
                        child: Text(
                          '设置',
                          style: TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen iOS System Settings secondary/tertiary page scaffold with standard
/// `< 返回` top navigation bar, dark inset-grouped background, and swipe-back support.
class IosSettingsScaffold extends StatelessWidget {
  final String title;
  final String backLabel;
  final Widget? trailing;
  final Widget body;

  const IosSettingsScaffold({
    super.key,
    required this.title,
    this.backLabel = '设置',
    this.trailing,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xF008080A),
                    Color(0xCC08080A),
                    Color(0x0008080A),
                  ],
                  stops: [0.0, 0.78, 1.0],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  top: mediaPadding.top + 4,
                  bottom: 6,
                  left: mediaPadding.left + 12,
                  right: mediaPadding.right + 12,
                ),
                child: SizedBox(
                  height: 42,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IosNativeGlassButton(
                          key: const ValueKey('settings-drawer-back'),
                          style: 'circle',
                          symbol: 'chevron.backward',
                          symbolSize: 17,
                          width: 40,
                          height: 40,
                          accessibilityLabel: backLabel,
                          onTap: () => Navigator.of(context).maybePop(),
                          fallback: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).maybePop(),
                            child: const LiquidGlass(
                              width: 40,
                              height: 40,
                              borderRadius: 20,
                              elevated: false,
                              tint: Color(0x521E1E22),
                              child: Center(
                                child: Icon(
                                  CupertinoIcons.back,
                                  color: AppleColors.labelPrimary,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 64),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (trailing != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: trailing!,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                bottom: false,
                child: RepaintBoundary(child: body),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class IosSettingsSubPage extends StatefulWidget {
  final SettingsPanes pages;
  final List<String> pathIds;
  final String parentTitle;
  final ValueNotifier<int> revision;
  final VoidCallback onChanged;

  const IosSettingsSubPage({
    super.key,
    required this.pages,
    required this.pathIds,
    required this.parentTitle,
    required this.revision,
    required this.onChanged,
  });

  @override
  State<IosSettingsSubPage> createState() => _IosSettingsSubPageState();
}

class _IosSettingsSubPageState extends State<IosSettingsSubPage> {
  void _refresh() {
    widget.onChanged();
    if (mounted) setState(() {});
  }

  SettingsPane _resolveCurrentPane() {
    // Resolve from fresh storage values on every rebuild, including after back
    // navigation. Do not retain a stale widget / selection in the page stack.
    final roots = widget.pages(_refresh);
    var pane = roots.firstWhere(
      (p) => p.id == widget.pathIds.first,
      orElse: () => roots.first,
    );
    for (var i = 1; i < widget.pathIds.length; i++) {
      final id = widget.pathIds[i];
      pane = pane.children.firstWhere(
        (p) => p.id == id,
        orElse: () => pane,
      );
    }
    return pane;
  }

  void _openChild(BuildContext context, SettingsPane current, SettingsPane child) {
    Navigator.of(context)
        .push<void>(
          buildApplePageRoute<void>(
            builder: (_) => IosSettingsSubPage(
              pages: widget.pages,
              pathIds: [...widget.pathIds, child.id],
              parentTitle: current.title,
              revision: widget.revision,
              onChanged: widget.onChanged,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.revision,
      builder: (context, _, __) {
        final pane = _resolveCurrentPane();
        final safeBottom = MediaQuery.paddingOf(context).bottom;
        final screenWidth = MediaQuery.sizeOf(context).width;
        final hPad = screenWidth >= 600 ? 24.0 : 18.0;
        return IosSettingsScaffold(
          title: pane.title,
          backLabel: widget.parentTitle,
          body: ListView(
            key: ValueKey('settings-page-${pane.id}'),
            padding: EdgeInsets.fromLTRB(hPad, 22, hPad, safeBottom + 40),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 740),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (pane.children.isNotEmpty) ...[
                        IosSettingsGroup(
                          footer: pane.subtitle.isNotEmpty ? pane.subtitle : null,
                          children: [
                            for (final child in pane.children)
                              IosSettingsRow(
                                key: ValueKey('settings-open-${child.id}'),
                                icon: child.icon,
                                iconColor: child.color,
                                title: child.title,
                                subtitle: child.subtitle.isNotEmpty
                                    ? child.subtitle
                                    : null,
                                trailingText: child.trailingText,
                                showChevron: true,
                                onTap: () => _openChild(context, pane, child),
                              ),
                          ],
                        ),
                        if (pane.content != null) const SizedBox(height: 24),
                      ],
                      if (pane.content != null) pane.content!,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Native iOS 26 System Settings inset-grouped table section (`#1C1C1E` 22pt
/// rounded card with `0.5pt` `#38383A` hairlines).
class IosSettingsGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final double dividerIndent;
  final List<Widget> children;

  const IosSettingsGroup({
    super.key,
    this.header,
    this.footer,
    this.dividerIndent = 58,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsGroup(header: header, footer: footer, children: children);
    }
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: dividerIndent, right: 16),
            color: const Color(0xA638383A),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null && header!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 7),
            child: Text(
              header!,
              style: const TextStyle(
                color: Color(0x99EBEBF5),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xF51C1C1E),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0x1EFFFFFF),
                width: 0.55,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: separated,
            ),
          ),
        ),
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
            child: Text(
              footer!,
              style: const TextStyle(
                color: Color(0x8CEBEBF5),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
      ],
    );
  }
}

/// Native iOS 26 System Settings cell with optional vivid `30×30` squircle icon
/// badge, title, optional subtitle, right-side detail text, or disclosure chevron.
class IosSettingsRow extends StatefulWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final int subtitleMaxLines;
  final String? trailingText;
  final Widget? trailing;
  final bool compact;
  final bool showChevron;
  final VoidCallback? onTap;

  const IosSettingsRow({
    super.key,
    this.icon,
    this.iconColor = AppleColors.systemBlue,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.trailingText,
    this.trailing,
    this.compact = false,
    this.showChevron = false,
    this.onTap,
  });

  @override
  State<IosSettingsRow> createState() => _IosSettingsRowState();
}

class _IosSettingsRowState extends State<IosSettingsRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsRow(title: widget.title, titleColor: widget.titleColor,
          subtitle: widget.subtitle, icon: widget.icon, value: widget.trailingText,
          trailing: widget.trailing, onTap: widget.onTap);
    }
    final hasSubtitle = widget.subtitle != null && widget.subtitle!.isNotEmpty;
    final minHeight = hasSubtitle
        ? 58.0
        : (widget.compact ? 46.0 : 50.0);
    final vPad = hasSubtitle
        ? 10.5
        : (widget.compact ? 8.5 : 10.5);
    final row = ColoredBox(
      color: _pressed ? const Color(0xFF2C2C2E) : const Color(0x00000000),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: vPad,
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(
                          const Color(0x28FFFFFF),
                          widget.iconColor,
                        ),
                        widget.iconColor,
                      ],
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(7.5),
                      side: const BorderSide(
                        color: Color(0x28FFFFFF),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(widget.icon, color: Colors.white, size: 16.5),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: widget.titleColor ?? AppleColors.labelPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (hasSubtitle) ...[
                      const SizedBox(height: 2.5),
                      Text(
                        widget.subtitle!,
                        maxLines: widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0x99EBEBF5),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailingText != null &&
                  widget.trailingText!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 148),
                    child: Text(
                      widget.trailingText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x99EBEBF5),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 10),
                widget.trailing!,
              ] else if (widget.showChevron) ...[
                const SizedBox(width: 6),
                const Icon(
                  CupertinoIcons.chevron_forward,
                  color: Color(0x66EBEBF5),
                  size: 14.5,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.onTap == null) return row;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: row,
      ),
    );
  }
}

/// Native iOS 26 System Settings switch row backed by genuine UIKit `UISwitch`
/// (with Liquid Glass expanding thumb on iOS 26+) and `CupertinoSwitch` fallback.
class IosSettingsSwitchRow extends StatelessWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const IosSettingsSwitchRow({
    super.key,
    this.icon,
    this.iconColor = AppleColors.systemBlue,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IosSettingsRow(
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      trailing: IosNativeSwitch(
        value: value,
        activeColor: AppleColors.systemGreen,
        accessibilityLabel: title,
        onChanged: onChanged,
      ),
    );
  }
}

/// Single selectable option cell inside an iOS System Settings checkmark group.
class IosSettingsChoiceTile extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const IosSettingsChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<IosSettingsChoiceTile> createState() => _IosSettingsChoiceTileState();
}

class _IosSettingsChoiceTileState extends State<IosSettingsChoiceTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: ColoredBox(
          color: _pressed ? const Color(0xFF2C2C2E) : const Color(0x00000000),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    const Icon(
                      CupertinoIcons.checkmark_alt,
                      color: AppleColors.systemBlue,
                      size: 19.5,
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

class SettingsChoices<T> extends StatelessWidget {
  final String title;
  final String? footer;
  final T value;
  final List<(T, String)> choices;
  final Future<void> Function(T) onSelected;
  const SettingsChoices({
    super.key,
    required this.title,
    this.footer,
    required this.value,
    required this.choices,
    required this.onSelected,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: IosSettingsGroup(
          header: title,
          footer: footer,
          dividerIndent: 18,
          children: [
            for (final choice in choices)
              IosSettingsChoiceTile(
                key: ValueKey('choice-$title-${choice.$1}'),
                label: choice.$2,
                selected: choice.$1 == value,
                onTap: () => onSelected(choice.$1),
              ),
          ],
        ),
      );
}

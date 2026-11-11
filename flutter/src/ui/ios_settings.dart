import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Material, MaterialType;
import 'apple_theme.dart';

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

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    _revision.value++;
    if (mounted) setState(() {});
    widget.onChanged();
  }

  void _openRootPane(BuildContext context, SettingsPane entry) {
    Navigator.of(context)
        .push<void>(
          CupertinoPageRoute<void>(
            builder: (_) => IosSettingsSubPage(
              pages: widget.pages,
              pathIds: [entry.id],
              parentTitle: '设置',
              revision: _revision,
              onChanged: _notifyChanged,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
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

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final entries = widget.pages(_notifyChanged);
    final grouped = _groupEntries(entries);
    return SafeArea(
      bottom: false,
      child: ListView(
        key: const ValueKey('ios-settings-root'),
        padding: EdgeInsets.fromLTRB(16, 10, 16, safeBottom + 104),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 2, 4, 14),
                    child: Text(
                      '设置',
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                      ),
                    ),
                  ),
                  for (var gIdx = 0; gIdx < grouped.length; gIdx++) ...[
                    if (gIdx > 0) const SizedBox(height: 20),
                    IosSettingsGroup(
                      children: [
                        for (final entry in grouped[gIdx])
                          IosSettingsRow(
                            key: ValueKey('settings-category-${entry.id}'),
                            icon: entry.icon,
                            iconColor: entry.color,
                            title: entry.title,
                            trailingText: entry.trailingText,
                            showChevron: true,
                            onTap: () => _openRootPane(context, entry),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
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
                color: Color(0xF0121214),
                border: Border(
                  bottom: BorderSide(color: Color(0x33545458), width: 0.5),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  top: mediaPadding.top,
                  left: mediaPadding.left,
                  right: mediaPadding.right,
                ),
                child: SizedBox(
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: CupertinoButton(
                          key: const ValueKey('settings-drawer-back'),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(44, 44),
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                CupertinoIcons.back,
                                color: AppleColors.systemBlue,
                                size: 21,
                              ),
                              Flexible(
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 112),
                                  child: Text(
                                    backLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppleColors.systemBlue,
                                      fontSize: 16.5,
                                      fontWeight: FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 116),
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
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: trailing!,
                          ),
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
                child: body,
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
          CupertinoPageRoute<void>(
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
        return IosSettingsScaffold(
          title: pane.title,
          backLabel: widget.parentTitle,
          body: ListView(
            key: ValueKey('settings-page-${pane.id}'),
            padding: EdgeInsets.fromLTRB(16, 18, 16, safeBottom + 32),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
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
                        if (pane.content != null) const SizedBox(height: 20),
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

/// Native iOS System Settings inset-grouped table section (`#1C1C1E` rounded card with `0.5pt` hairlines).
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
    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: dividerIndent),
            color: const Color(0x38545458),
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
                fontWeight: FontWeight.w400,
                letterSpacing: -0.05,
              ),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0x16FFFFFF),
                width: 0.5,
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
            padding: const EdgeInsets.only(left: 16, right: 16, top: 7),
            child: Text(
              footer!,
              style: const TextStyle(
                color: Color(0x99EBEBF5),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
      ],
    );
  }
}

/// Native iOS System Settings cell with optional vivid squircle icon badge, title,
/// optional subtitle, right-side detail text, or disclosure chevron.
class IosSettingsRow extends StatefulWidget {
  final IconData? icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  const IosSettingsRow({
    super.key,
    this.icon,
    this.iconColor = AppleColors.systemBlue,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailingText,
    this.trailing,
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
    final row = ColoredBox(
      color: _pressed ? const Color(0xFF2C2C2E) : const Color(0x00000000),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: widget.iconColor,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: SizedBox(
                    width: 29,
                    height: 29,
                    child: Icon(widget.icon, color: Colors.white, size: 17),
                  ),
                ),
                const SizedBox(width: 13),
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
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        maxLines: 2,
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
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      widget.trailingText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x99EBEBF5),
                        fontSize: 15.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
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

/// Native iOS System Settings switch row (`CupertinoSwitch`).
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
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: AppleColors.systemGreen,
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
            constraints: const BoxConstraints(minHeight: 46),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    const Icon(
                      CupertinoIcons.checkmark_alt,
                      color: AppleColors.systemBlue,
                      size: 19,
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
        padding: const EdgeInsets.only(bottom: 20),
        child: IosSettingsGroup(
          header: title,
          footer: footer,
          dividerIndent: 16,
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

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/cast_avatar_service.dart';
import 'apple_theme.dart';
import 'desktop_horizontal_scroller.dart';
import 'poster_image.dart';
import 'windows_appearance.dart';

/// Horizontal circular actor/director avatar carousel used on the Detail page
/// (including Windows Desktop) with automatic Douban portrait lookup and
/// immediate monogram fallback from CMS `vod_actor`.
class CastAvatarSection extends StatefulWidget {
  final String title;
  final String actorRaw;
  final String year;
  final String doubanId;
  final List<CastMember>? initialMembers;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? containerMargin;
  final EdgeInsetsGeometry? containerPadding;
  final BoxDecoration? containerDecoration;
  final bool forceDark;
  final bool allowExternalLookup;
  final ValueChanged<CastMember>? onTapMember;

  const CastAvatarSection({
    super.key,
    required this.title,
    this.actorRaw = '',
    this.year = '',
    this.doubanId = '',
    this.initialMembers,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.containerMargin,
    this.containerPadding,
    this.containerDecoration,
    this.forceDark = false,
    this.allowExternalLookup = true,
    this.onTapMember,
  });

  @override
  State<CastAvatarSection> createState() => _CastAvatarSectionState();
}

class _CastAvatarSectionState extends State<CastAvatarSection> {
  final ScrollController _scrollController = ScrollController();
  List<CastMember> _members = const [];
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CastAvatarSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.actorRaw != widget.actorRaw ||
        oldWidget.doubanId != widget.doubanId ||
        oldWidget.allowExternalLookup != widget.allowExternalLookup ||
        oldWidget.initialMembers != widget.initialMembers) {
      _initAndLoad();
    }
  }

  void _initAndLoad() {
    final gen = ++_generation;
    if (widget.initialMembers != null) {
      _members = widget.initialMembers!;
      _loading = false;
      return;
    }
    if (!widget.allowExternalLookup) {
      _members = CastAvatarService.parseRawActors(widget.actorRaw);
      _loading = false;
      return;
    }
    final cached = CastAvatarService.peekCached(widget.title);
    if (cached != null && cached.isNotEmpty) {
      _members = cached;
      _loading = false;
      return;
    }
    _members = CastAvatarService.parseRawActors(widget.actorRaw);
    _loading = widget.title.trim().isNotEmpty || _members.isNotEmpty;
    if (!_loading) return;
    CastAvatarService.resolveCast(
      title: widget.title,
      actorRaw: widget.actorRaw,
      year: widget.year,
      doubanId: widget.doubanId,
      onProgress: (updated) {
        if (!mounted || gen != _generation || updated.isEmpty) return;
        setState(() {
          _members = updated;
        });
      },
    ).then((resolved) {
      if (!mounted || gen != _generation) return;
      setState(() {
        if (resolved.isNotEmpty) {
          _members = resolved;
        }
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_members.isEmpty && !_loading) return const SizedBox.shrink();
    final winScope = WindowsAppearanceScope.maybeOf(context);
    final isDark =
        widget.forceDark || (winScope != null ? winScope.dark : true);
    final primaryColor = widget.forceDark
        ? AppleColors.labelPrimary
        : (winScope != null ? winInk(context) : AppleColors.labelPrimary);
    final secondaryColor = widget.forceDark
        ? AppleColors.labelTertiary
        : (winScope != null ? winMuted(context) : AppleColors.labelTertiary);

    final body = Column(
      key: const Key('cast-avatar-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: widget.padding,
          child: Row(
            children: [
              Text(
                '演职员',
                style: TextStyle(
                  color: primaryColor,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (_members.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${_members.length}',
                  style: TextStyle(
                    color: secondaryColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_loading && _members.isEmpty) ...[
                const SizedBox(width: 8),
                CupertinoActivityIndicator(
                  radius: 7,
                  color: secondaryColor,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 112,
          child: DesktopHorizontalScroller(
            controller: _scrollController,
            child: _members.isEmpty
                ? ListView.separated(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    padding: widget.padding,
                    itemCount: 6,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (_, __) => _CastSkeletonItem(isDark: isDark),
                  )
                : ListView.separated(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    padding: widget.padding,
                    itemCount: _members.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      return _CastAvatarCard(
                        member: member,
                        isDark: isDark,
                        primaryColor: primaryColor,
                        secondaryColor: secondaryColor,
                        onTap: widget.onTapMember != null
                            ? () => widget.onTapMember!(member)
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ],
    );

    if (widget.containerDecoration == null &&
        widget.containerPadding == null &&
        widget.containerMargin == null) {
      return body;
    }
    return Container(
      margin: widget.containerMargin,
      padding: widget.containerPadding,
      decoration: widget.containerDecoration,
      child: body,
    );
  }
}

class _CastAvatarCard extends StatelessWidget {
  final CastMember member;
  final bool isDark;
  final Color primaryColor;
  final Color secondaryColor;
  final VoidCallback? onTap;

  const _CastAvatarCard({
    required this.member,
    required this.isDark,
    required this.primaryColor,
    required this.secondaryColor,
    this.onTap,
  });

  static const List<List<Color>> _monogramGradients = [
    [Color(0xFF4A6CF7), Color(0xFF2F45C5)],
    [Color(0xFFE05D6F), Color(0xFFA9364C)],
    [Color(0xFF2BA89C), Color(0xFF196E6C)],
    [Color(0xFFD9822B), Color(0xFF9F5114)],
    [Color(0xFF845EF7), Color(0xFF5333B5)],
    [Color(0xFF3A9BDC), Color(0xFF1E6091)],
  ];

  @override
  Widget build(BuildContext context) {
    final gradient = _monogramGradients[
        member.name.hashCode.abs() % _monogramGradients.length];
    final initial = member.name.isNotEmpty
        ? String.fromCharCode(member.name.runes.first).toUpperCase()
        : '?';

    final fallbackAvatar = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    final avatar = Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.black.withValues(alpha: 0.08),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: member.avatarUrl.isNotEmpty
            ? PosterImage(
                url: member.avatarUrl,
                title: '',
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                fadeIn: true,
                placeholder: fallbackAvatar,
              )
            : fallbackAvatar,
      ),
    );

    final card = SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          avatar,
          const SizedBox(height: 7),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: primaryColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.15,
            ),
          ),
          if (member.role.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              member.role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryColor,
                fontSize: 10.5,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return KeyedSubtree(
        key: Key('cast-avatar-item-${member.name}'),
        child: card,
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('cast-avatar-item-${member.name}'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: card,
      ),
    );
  }
}

class _CastSkeletonItem extends StatelessWidget {
  final bool isDark;
  const _CastSkeletonItem({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final fill = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
          ),
          const SizedBox(height: 7),
          Container(
            width: 46,
            height: 10,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 32,
            height: 8,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

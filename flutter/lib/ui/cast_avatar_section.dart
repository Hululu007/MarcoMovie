import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/cast_avatar_service.dart';
import 'apple_theme.dart';
import 'poster_image.dart';

/// Horizontal circular actor/director avatar carousel used on both the Detail
/// page (选集页) and the iOS Portrait Companion Player (腾讯视频模式).
class CastAvatarSection extends StatefulWidget {
  final String title;
  final String actorRaw;
  final String year;
  final String doubanId;
  final List<CastMember>? initialMembers;
  final EdgeInsetsGeometry padding;
  final bool forceDark;
  final ValueChanged<CastMember>? onTapMember;

  const CastAvatarSection({
    super.key,
    required this.title,
    this.actorRaw = '',
    this.year = '',
    this.doubanId = '',
    this.initialMembers,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.forceDark = false,
    this.onTapMember,
  });

  @override
  State<CastAvatarSection> createState() => _CastAvatarSectionState();
}

class _CastAvatarSectionState extends State<CastAvatarSection> {
  List<CastMember> _members = const [];
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  @override
  void didUpdateWidget(covariant CastAvatarSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.actorRaw != widget.actorRaw ||
        oldWidget.doubanId != widget.doubanId ||
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
    final cached = CastAvatarService.peekCached(widget.title);
    if (cached != null && cached.isNotEmpty) {
      _members = cached;
      _loading = false;
      return;
    }
    _members = CastAvatarService.parseRawActors(widget.actorRaw);
    _loading = widget.title.trim().isNotEmpty;
    if (!_loading) return;
    CastAvatarService.resolveCast(
      title: widget.title,
      actorRaw: widget.actorRaw,
      year: widget.year,
      doubanId: widget.doubanId,
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
    final palette = widget.forceDark ? ApplePalette.dark : ApplePalette.of(context);
    return Column(
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
                  color: palette.labelPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (_members.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${_members.length}',
                  style: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_loading && _members.isEmpty) ...[
                const SizedBox(width: 8),
                CupertinoActivityIndicator(
                  radius: 7,
                  color: palette.labelTertiary,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 104,
          child: _members.isEmpty
              ? ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: widget.padding,
                  itemCount: 5,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, __) => _CastSkeletonItem(palette: palette),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: widget.padding,
                  itemCount: _members.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final member = _members[index];
                    return _CastAvatarCard(
                      member: member,
                      palette: palette,
                      onTap: widget.onTapMember != null
                          ? () => widget.onTapMember!(member)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CastAvatarCard extends StatelessWidget {
  final CastMember member;
  final ApplePalette palette;
  final VoidCallback? onTap;

  const _CastAvatarCard({
    required this.member,
    required this.palette,
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
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: palette.isDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.black.withValues(alpha: 0.08),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: palette.isDark ? 0.28 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: member.avatarUrl.isNotEmpty
            ? PosterImage(
                url: member.avatarUrl,
                title: member.name,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                fadeIn: true,
                placeholder: fallbackAvatar,
              )
            : fallbackAvatar,
      ),
    );

    return GestureDetector(
      key: Key('cast-avatar-item-${member.name}'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar,
            const SizedBox(height: 6),
            Text(
              member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.15,
              ),
            ),
            if (member.role.isNotEmpty) ...[
              const SizedBox(height: 1.5),
              Text(
                member.role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.labelTertiary,
                  fontSize: 10,
                  height: 1.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CastSkeletonItem extends StatelessWidget {
  final ApplePalette palette;
  const _CastSkeletonItem({required this.palette});

  @override
  Widget build(BuildContext context) {
    final fill = palette.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return SizedBox(
      width: 68,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
          ),
          const SizedBox(height: 7),
          Container(
            width: 44,
            height: 10,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 30,
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

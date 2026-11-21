import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/curated_discovery.dart';
import '../core/models.dart';
import 'apple_theme.dart';
import 'poster_image.dart';

/// Rex-style curated discovery section rendered on the Home screen alongside
/// the user's own source posters (近期国内热门、豆瓣高分、烂番茄、迪士尼、漫威、DC).
class CuratedDiscoverySection extends StatefulWidget {
  final ValueChanged<CmsVideo> onOpenVideo;
  final bool hasUserSources;
  final bool loadLive;

  const CuratedDiscoverySection({
    super.key,
    required this.onOpenVideo,
    required this.hasUserSources,
    this.loadLive = true,
  });

  @override
  State<CuratedDiscoverySection> createState() =>
      _CuratedDiscoverySectionState();
}

class _CuratedDiscoverySectionState extends State<CuratedDiscoverySection> {
  final Map<String, List<CmsVideo>> _itemsByModule = {};
  String _selectedModuleId = '';

  @override
  void initState() {
    super.initState();
    for (final spec in CuratedDiscoveryService.modules) {
      _itemsByModule[spec.id] = CuratedDiscoveryService.peekModule(spec);
    }
    if (widget.loadLive) {
      _refreshModules();
    }
  }

  Future<void> _refreshModules() async {
    for (final spec in CuratedDiscoveryService.modules) {
      final fetched = await CuratedDiscoveryService.fetchModule(spec);
      if (!mounted) return;
      setState(() {
        _itemsByModule[spec.id] = fetched;
      });
    }
  }

  void _openModuleAll(CuratedModuleSpec spec) {
    HapticFeedback.selectionClick();
    final items = _itemsByModule[spec.id] ?? spec.seedItems;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => _CuratedModuleGridPage(
          spec: spec,
          items: items,
          hasUserSources: widget.hasUserSources,
          onOpenVideo: widget.onOpenVideo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    return Column(
      key: const Key('curated-discovery-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Text(
                '片单发现',
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    widget.hasUserSources ? '点播自动匹配已添片源' : '需先添加片源方可播放',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _CuratedModulePill(
                label: '全部专题',
                selected: _selectedModuleId.isEmpty,
                accentColor: palette.accent,
                palette: palette,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedModuleId = '');
                },
              ),
              for (final spec in CuratedDiscoveryService.modules) ...[
                const SizedBox(width: 8),
                _CuratedModulePill(
                  label: spec.title,
                  selected: _selectedModuleId == spec.id,
                  accentColor: spec.accentColor,
                  palette: palette,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _selectedModuleId =
                          _selectedModuleId == spec.id ? '' : spec.id;
                    });
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final spec in CuratedDiscoveryService.modules)
          if (_selectedModuleId.isEmpty || _selectedModuleId == spec.id) ...[
            _CuratedModuleShelf(
              spec: spec,
              items: _itemsByModule[spec.id] ?? spec.seedItems,
              palette: palette,
              onOpenAll: () => _openModuleAll(spec),
              onOpenVideo: widget.onOpenVideo,
            ),
            const SizedBox(height: 18),
          ],
      ],
    );
  }
}

class _CuratedModulePill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accentColor;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _CuratedModulePill({
    required this.label,
    required this.selected,
    required this.accentColor,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: palette.isDark ? 0.24 : 0.14)
              : (palette.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? accentColor.withValues(alpha: 0.72)
                : (palette.isDark
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.black.withValues(alpha: 0.08)),
            width: 0.85,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? accentColor : palette.labelSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CuratedModuleShelf extends StatelessWidget {
  final CuratedModuleSpec spec;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final VoidCallback onOpenAll;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _CuratedModuleShelf({
    required this.spec,
    required this.items,
    required this.palette,
    required this.onOpenAll,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: Key('curated-module-${spec.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: spec.accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(spec.icon, size: 14, color: spec.accentColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spec.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      spec.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: const Size(28, 28),
                onPressed: onOpenAll,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看更多',
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 13,
                      color: palette.labelTertiary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 204,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 11),
            itemBuilder: (context, index) {
              final video = items[index];
              return _CuratedPosterCard(
                video: video,
                accentColor: spec.accentColor,
                palette: palette,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onOpenVideo(video);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CuratedPosterCard extends StatelessWidget {
  final CmsVideo video;
  final Color accentColor;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _CuratedPosterCard({
    required this.video,
    required this.accentColor,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeText = video.rtScore != null
        ? '🍅 ${video.rtScore}%'
        : (video.doubanScore != null
            ? '豆 ${video.doubanScore!.toStringAsFixed(1)}'
            : video.year);

    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.isDark
              ? const [Color(0xFF23252C), Color(0xFF15161B)]
              : const [Color(0xFFECEEF3), Color(0xFFDFE3EC)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
      child: Text(
        video.title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: palette.labelTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return GestureDetector(
      key: Key('curated-poster-${video.id}'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: palette.isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.06),
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: palette.isDark ? 0.32 : 0.09,
                      ),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: video.poster,
                        title: video.title,
                        year: video.year,
                        fit: BoxFit.cover,
                        fadeIn: true,
                        placeholder: placeholder,
                      ),
                      if (badgeText.isNotEmpty)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5.5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.68),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badgeText,
                              style: const TextStyle(
                                color: Color(0xFFFFD86B),
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (video.year.isNotEmpty)
              Text(
                video.year,
                maxLines: 1,
                style: TextStyle(
                  color: palette.labelTertiary,
                  fontSize: 10.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CuratedModuleGridPage extends StatelessWidget {
  final CuratedModuleSpec spec;
  final List<CmsVideo> items;
  final bool hasUserSources;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _CuratedModuleGridPage({
    required this.spec,
    required this.items,
    required this.hasUserSources,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: CupertinoNavigationBar(
        backgroundColor: palette.navBarBg,
        middle: Text(
          spec.title,
          style: TextStyle(color: palette.labelPrimary),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          childAspectRatio: 0.58,
          crossAxisSpacing: 12,
          mainAxisSpacing: 14,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final v = items[index];
          return _CuratedPosterCard(
            video: v,
            accentColor: spec.accentColor,
            palette: palette,
            onTap: () {
              HapticFeedback.selectionClick();
              onOpenVideo(v);
            },
          );
        },
      ),
    );
  }
}

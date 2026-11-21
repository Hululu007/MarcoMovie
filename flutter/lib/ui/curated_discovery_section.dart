import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/curated_discovery.dart';
import '../core/models.dart';
import 'apple_theme.dart';
import 'poster_image.dart';

/// Multi-style Rex / Apple TV-inspired curated discovery feed rendered on the
/// Home screen alongside the user's own source posters:
/// - Portrait poster shelf (`近期国内热门`)
/// - 16:9 landscape widescreen shelf (`本周趋势`)
/// - Editorial laurel-wreath collection carousel (`近一月 · 热门综艺 / 热门剧集`)
/// - Stylized studio fan-collage cards (`精选厂牌`: Disney+, MARVEL, DC)
/// - Stacked-poster category pills (`分类浏览`)
/// - Staggered 3-row poster mosaic cards (`高分片单`: 豆瓣高分, 烂番茄口碑)
///
/// Tapping any collection / studio / category / mosaic card launches
/// [_CuratedGravityWallPage] with a 2-phase physics transition: posters drop
/// under gravity into a bouncy stacked pile, then spring-expand into an
/// interactive 3-column poster wall.
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

  CuratedModuleSpec _specById(String id) {
    return CuratedDiscoveryService.modules.firstWhere(
      (m) => m.id == id,
      orElse: () => CuratedDiscoveryService.modules.first,
    );
  }

  List<CmsVideo> _itemsFor(String id) {
    final spec = _specById(id);
    return _itemsByModule[id] ?? spec.seedItems;
  }

  void _openCollectionWithGravityWall(
    CuratedModuleSpec spec, {
    String? customTitle,
    List<CmsVideo>? customItems,
  }) {
    HapticFeedback.mediumImpact();
    final items = customItems ?? _itemsFor(spec.id);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => _CuratedGravityWallPage(
          title: customTitle ?? spec.title,
          subtitle: spec.subtitle,
          accentColor: spec.accentColor,
          items: items,
          hasUserSources: widget.hasUserSources,
          onOpenVideo: widget.onOpenVideo,
        ),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final cnHotSpec = _specById('cn_hot');
    final trendingSpec = _specById('weekly_trending');
    final varietySpec = _specById('cn_variety');
    final doubanSpec = _specById('douban_top');
    final rtSpec = _specById('rotten_tomatoes');
    final disneySpec = _specById('disney');
    final marvelSpec = _specById('marvel');
    final dcSpec = _specById('dc');

    return Column(
      key: const Key('curated-discovery-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Portrait Poster Shelf — `近期国内热门` (Ref Image 1 top)
        _PortraitDiscoveryShelf(
          key: Key('curated-module-${cnHotSpec.id}'),
          title: cnHotSpec.title,
          accentColor: cnHotSpec.accentColor,
          items: _itemsFor(cnHotSpec.id),
          palette: palette,
          onOpenAll: () => _openCollectionWithGravityWall(cnHotSpec),
          onOpenVideo: widget.onOpenVideo,
        ),
        const SizedBox(height: 22),

        // 2. Widescreen 16:9 Landscape Shelf — `本周趋势` (Ref Image 1 bottom & Ref Image 3 top)
        _LandscapeDiscoveryShelf(
          key: Key('curated-module-${trendingSpec.id}'),
          title: trendingSpec.title,
          accentColor: trendingSpec.accentColor,
          items: _itemsFor(trendingSpec.id),
          palette: palette,
          onOpenAll: () => _openCollectionWithGravityWall(trendingSpec),
          onOpenVideo: widget.onOpenVideo,
        ),
        const SizedBox(height: 24),

        // 3. Editorial Laurel-Wreath Collection Carousel — `近一月 · 热门综艺 / 热门剧集 / 豆瓣高分 / 烂番茄` (Ref Images 3 & 4)
        SingleChildScrollView(
          key: const Key('curated-editorial-collections'),
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _EditorialCollectionCard(
                key: Key('curated-module-${varietySpec.id}'),
                title: '近一月 · 热门综艺',
                items: _itemsFor(varietySpec.id),
                tintBase: palette.isDark
                    ? const Color(0xFF474139)
                    : const Color(0xFF7B7062),
                accentColor: varietySpec.accentColor,
                onOpenCollection: () => _openCollectionWithGravityWall(
                  varietySpec,
                  customTitle: '近一月 · 热门综艺',
                ),
                onOpenVideo: widget.onOpenVideo,
              ),
              const SizedBox(width: 14),
              _EditorialCollectionCard(
                key: const Key('curated-editorial-cn-drama'),
                title: '近一月 · 热门剧集',
                items: _itemsFor(cnHotSpec.id),
                tintBase: palette.isDark
                    ? const Color(0xFF28302F)
                    : const Color(0xFF435453),
                accentColor: cnHotSpec.accentColor,
                onOpenCollection: () => _openCollectionWithGravityWall(
                  cnHotSpec,
                  customTitle: '近一月 · 热门剧集',
                ),
                onOpenVideo: widget.onOpenVideo,
              ),
              const SizedBox(width: 14),
              _EditorialCollectionCard(
                key: const Key('curated-editorial-douban'),
                title: '豆瓣高分 · 必看榜',
                items: _itemsFor(doubanSpec.id),
                tintBase: palette.isDark
                    ? const Color(0xFF1F3027)
                    : const Color(0xFF335243),
                accentColor: doubanSpec.accentColor,
                onOpenCollection: () => _openCollectionWithGravityWall(
                  doubanSpec,
                  customTitle: '豆瓣高分 · 必看榜',
                ),
                onOpenVideo: widget.onOpenVideo,
              ),
              const SizedBox(width: 14),
              _EditorialCollectionCard(
                key: const Key('curated-editorial-rt'),
                title: '烂番茄 · 口碑认证',
                items: _itemsFor(rtSpec.id),
                tintBase: palette.isDark
                    ? const Color(0xFF372226)
                    : const Color(0xFF5D383F),
                accentColor: rtSpec.accentColor,
                onOpenCollection: () => _openCollectionWithGravityWall(
                  rtSpec,
                  customTitle: '烂番茄 · 口碑认证',
                ),
                onOpenVideo: widget.onOpenVideo,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 4. Stylized Brand / Studio Fan-Collage Cards — `精选厂牌` (Ref Image 2 top)
        _SectionHeaderRow(
          title: '精选厂牌',
          palette: palette,
          badgeText: widget.hasUserSources ? '点播自动匹配片源' : '需添加片源播放',
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          key: const Key('curated-studio-shelf'),
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _StudioFanCard(
                key: Key('curated-module-${disneySpec.id}'),
                style: _StudioBrandStyle.disney,
                spec: disneySpec,
                items: _itemsFor(disneySpec.id),
                onTap: () => _openCollectionWithGravityWall(disneySpec),
              ),
              const SizedBox(width: 12),
              _StudioFanCard(
                key: Key('curated-module-${marvelSpec.id}'),
                style: _StudioBrandStyle.marvel,
                spec: marvelSpec,
                items: _itemsFor(marvelSpec.id),
                onTap: () => _openCollectionWithGravityWall(marvelSpec),
              ),
              const SizedBox(width: 12),
              _StudioFanCard(
                key: Key('curated-module-${dcSpec.id}'),
                style: _StudioBrandStyle.dc,
                spec: dcSpec,
                items: _itemsFor(dcSpec.id),
                onTap: () => _openCollectionWithGravityWall(dcSpec),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        // 5. Stacked Mini-Poster Category Pills — `分类浏览` (Ref Image 2 middle)
        _SectionHeaderRow(
          title: '分类浏览',
          palette: palette,
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          key: const Key('curated-category-pills'),
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final entry in [
                (spec: disneySpec, label: '合家欢'),
                (spec: cnHotSpec, label: '热播剧集'),
                (spec: varietySpec, label: '热门综艺'),
                (spec: trendingSpec, label: '院线趋势'),
                (spec: marvelSpec, label: '漫威英雄'),
                (spec: dcSpec, label: 'DC 史诗'),
              ]) ...[
                _StackedCategoryPill(
                  label: entry.label,
                  items: _itemsFor(entry.spec.id),
                  palette: palette,
                  onTap: () => _openCollectionWithGravityWall(
                    entry.spec,
                    customTitle: entry.label,
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),

        // 6. Staggered 3-Row Poster-Wall Mosaic Cards — `高分剧集 / 高分电影` (Ref Image 2 bottom)
        SingleChildScrollView(
          key: const Key('curated-mosaic-shelf'),
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _PosterWallMosaicCard(
                key: Key('curated-module-${doubanSpec.id}'),
                title: '豆瓣高分',
                subtitle: '影迷公认必看佳片',
                items: _itemsFor(doubanSpec.id),
                accentColor: doubanSpec.accentColor,
                palette: palette,
                onTap: () => _openCollectionWithGravityWall(doubanSpec),
              ),
              const SizedBox(width: 14),
              _PosterWallMosaicCard(
                key: Key('curated-module-${rtSpec.id}'),
                title: '烂番茄口碑',
                subtitle: '海外影评新鲜认证',
                items: _itemsFor(rtSpec.id),
                accentColor: rtSpec.accentColor,
                palette: palette,
                onTap: () => _openCollectionWithGravityWall(rtSpec),
              ),
              const SizedBox(width: 14),
              _PosterWallMosaicCard(
                key: const Key('curated-mosaic-hero-universe'),
                title: '超英宇宙',
                subtitle: '漫威 · DC 史诗合集',
                items: [
                  ..._itemsFor(marvelSpec.id).take(6),
                  ..._itemsFor(dcSpec.id).take(6),
                ],
                accentColor: marvelSpec.accentColor,
                palette: palette,
                onTap: () => _openCollectionWithGravityWall(
                  marvelSpec,
                  customTitle: '漫威 · DC 超英宇宙',
                  customItems: [
                    ..._itemsFor(marvelSpec.id),
                    ..._itemsFor(dcSpec.id),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  final String title;
  final ApplePalette palette;
  final String? badgeText;
  final VoidCallback? onTapChevron;

  const _SectionHeaderRow({
    required this.title,
    required this.palette,
    this.badgeText,
    this.onTapChevron,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: palette.labelPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.35,
            ),
          ),
          if (badgeText != null && badgeText!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2.5),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeText!,
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
          const Spacer(),
          if (onTapChevron != null)
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              minimumSize: const Size(28, 28),
              onPressed: onTapChevron,
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: palette.labelTertiary,
              ),
            ),
        ],
      ),
    );
  }
}

/// Ref Image 1 Top: Clean 2:3 vertical poster shelf (`近期国内热门`).
class _PortraitDiscoveryShelf extends StatelessWidget {
  final String title;
  final Color accentColor;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final VoidCallback onOpenAll;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _PortraitDiscoveryShelf({
    super.key,
    required this.title,
    required this.accentColor,
    required this.items,
    required this.palette,
    required this.onOpenAll,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeaderRow(
          title: title,
          palette: palette,
          onTapChevron: onOpenAll,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 11),
            itemBuilder: (context, index) {
              final video = items[index];
              return _CuratedPosterCard(
                video: video,
                accentColor: accentColor,
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

/// Ref Image 1 Bottom & Ref Image 3 Top: Wide 16:9 landscape cards (`本周趋势`).
class _LandscapeDiscoveryShelf extends StatelessWidget {
  final String title;
  final Color accentColor;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final VoidCallback onOpenAll;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _LandscapeDiscoveryShelf({
    super.key,
    required this.title,
    required this.accentColor,
    required this.items,
    required this.palette,
    required this.onOpenAll,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeaderRow(
          title: title,
          palette: palette,
          onTapChevron: onOpenAll,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 162,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final video = items[index];
              return _CuratedLandscapeCard(
                video: video,
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

class _CuratedLandscapeCard extends StatelessWidget {
  final CmsVideo video;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _CuratedLandscapeCard({
    required this.video,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final genre = CuratedDiscoveryService.genreFor(video);
    final metaParts = <String>[
      if (video.year.isNotEmpty) video.year,
      if (genre.isNotEmpty)
        genre
      else if (video.remarks.isNotEmpty)
        video.remarks,
    ];
    final subtitle = metaParts.join(' · ');
    final imgUrl = CuratedDiscoveryService.backdropFor(video);

    return GestureDetector(
      key: Key('curated-landscape-${video.id}'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 210,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 210,
              height: 118,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: palette.isDark
                      ? Colors.white.withValues(alpha: 0.11)
                      : Colors.black.withValues(alpha: 0.06),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: palette.isDark ? 0.32 : 0.10,
                    ),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13.5),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      url: imgUrl,
                      title: video.title,
                      year: video.year,
                      fit: BoxFit.cover,
                      forBackdrop: true,
                      highRes: true,
                      placeholder: _buildFallbackThumb(video.title, palette),
                    ),
                    // Subtle cinematic bottom vignette
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.08),
                              Colors.black.withValues(alpha: 0.42),
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                    if (video.doubanScore != null || video.rtScore != null)
                      Positioned(
                        top: 7,
                        right: 7,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            video.rtScore != null
                                ? '🍅 ${video.rtScore}%'
                                : '豆 ${video.doubanScore!.toStringAsFixed(1)}',
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
            const SizedBox(height: 7),
            Text(
              video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.15,
              ),
            ),
            if (subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.labelTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ref Images 3 & 4: Editorial Laurel-Wreath Collection Card (`近一月 · 热门综艺 / 热门剧集`)
/// with top full-bleed spotlight + laurel title + bottom 2-up 16:9 mini-cards.
class _EditorialCollectionCard extends StatelessWidget {
  final String title;
  final List<CmsVideo> items;
  final Color tintBase;
  final Color accentColor;
  final VoidCallback onOpenCollection;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _EditorialCollectionCard({
    super.key,
    required this.title,
    required this.items,
    required this.tintBase,
    required this.accentColor,
    required this.onOpenCollection,
    required this.onOpenVideo,
  });

  @override
  Widget build(BuildContext context) {
    final heroItem = items.isNotEmpty ? items.first : null;
    final subItems = items.length > 2
        ? items.sublist(1, 3)
        : (items.length == 2 ? items : items.take(2).toList(growable: false));
    final heroBackdrop =
        heroItem != null ? CuratedDiscoveryService.backdropFor(heroItem) : '';

    return GestureDetector(
      onTap: onOpenCollection,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 306,
        height: 322,
        decoration: BoxDecoration(
          color: tintBase,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21.5),
          child: Column(
            children: [
              // Top 54%: Spotlight HD backdrop + Laurel Wreath Title
              SizedBox(
                height: 174,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (heroItem != null)
                      PosterImage(
                        url: heroBackdrop,
                        title: heroItem.title,
                        year: heroItem.year,
                        fit: BoxFit.cover,
                        forBackdrop: true,
                        highRes: true,
                        placeholder: Container(color: tintBase),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.12),
                            tintBase.withValues(alpha: 0.38),
                            tintBase.withValues(alpha: 0.96),
                          ],
                          stops: const [0.0, 0.56, 1.0],
                        ),
                      ),
                    ),
                    // Top-right expand hint pill
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.42),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                            width: 0.6,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '共 ${items.length} 部',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 2),
                            const Icon(
                              CupertinoIcons.chevron_right,
                              size: 10,
                              color: Colors.white70,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Centered Laurel-Wreath Title + Spotlight Name
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 10,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const _LaurelWreathIcon(flip: false),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                    shadows: [
                                      Shadow(
                                        color: Color(0x88000000),
                                        blurRadius: 10,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const _LaurelWreathIcon(flip: true),
                            ],
                          ),
                          if (heroItem != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              heroItem.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.78),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Bottom 46%: 2-column 16:9 mini-cards inside the collection frame
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  decoration: BoxDecoration(
                    color: tintBase.withValues(alpha: 0.94),
                  ),
                  child: Row(
                    children: [
                      for (int i = 0; i < subItems.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _EditorialMiniWideTile(
                            video: subItems[i],
                            onTap: () {
                              HapticFeedback.selectionClick();
                              onOpenVideo(subItems[i]);
                            },
                          ),
                        ),
                      ],
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

class _EditorialMiniWideTile extends StatelessWidget {
  final CmsVideo video;
  final VoidCallback onTap;

  const _EditorialMiniWideTile({
    required this.video,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final genre = CuratedDiscoveryService.genreFor(video);
    final sub = [
      if (video.year.isNotEmpty) video.year,
      if (genre.isNotEmpty)
        genre
      else if (video.remarks.isNotEmpty)
        video.remarks,
    ].join(' · ');

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(
                    url: CuratedDiscoveryService.backdropFor(video),
                    title: video.title,
                    year: video.year,
                    fit: BoxFit.cover,
                    forBackdrop: true,
                    placeholder: Container(
                      color: Colors.black.withValues(alpha: 0.28),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 0.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (sub.isNotEmpty)
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 10.5,
              ),
            ),
        ],
      ),
    );
  }
}

/// Custom vector laurel wreath flanking editorial collection titles (Ref Images 3 & 4).
class _LaurelWreathIcon extends StatelessWidget {
  final bool flip;

  const _LaurelWreathIcon({required this.flip});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scaleX: flip ? -1.0 : 1.0,
      child: CustomPaint(
        size: const Size(16, 28),
        painter: _LaurelPainter(),
      ),
    );
  }
}

class _LaurelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stemPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    final stem = Path()
      ..moveTo(size.width * 0.78, size.height * 0.92)
      ..quadraticBezierTo(
        size.width * 0.18,
        size.height * 0.55,
        size.width * 0.58,
        size.height * 0.08,
      );
    canvas.drawPath(stem, stemPaint);

    final leafPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.90)
      ..style = PaintingStyle.fill;

    const leafOffsets = [
      (0.32, 0.22, -0.55),
      (0.24, 0.42, -0.35),
      (0.28, 0.62, -0.15),
      (0.45, 0.78, 0.15),
      (0.55, 0.30, 0.45),
      (0.48, 0.52, 0.55),
      (0.58, 0.70, 0.65),
    ];
    for (final (fx, fy, angle) in leafOffsets) {
      canvas.save();
      canvas.translate(size.width * fx, size.height * fy);
      canvas.rotate(angle);
      canvas.drawOval(
        const Rect.fromLTWH(-3.2, -1.6, 6.4, 3.2),
        leafPaint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _StudioBrandStyle { disney, marvel, dc }

/// Ref Image 2 Top: Wide studio card with bold brand emblem on the left and a
/// 3D-tilted diagonal multi-poster collage fan on the right.
class _StudioFanCard extends StatelessWidget {
  final _StudioBrandStyle style;
  final CuratedModuleSpec spec;
  final List<CmsVideo> items;
  final VoidCallback onTap;

  const _StudioFanCard({
    super.key,
    required this.style,
    required this.spec,
    required this.items,
    required this.onTap,
  });

  List<Color> get _gradientColors => switch (style) {
        _StudioBrandStyle.disney => const [
            Color(0xFF0E1B36),
            Color(0xFF142A54),
          ],
        _StudioBrandStyle.marvel => const [
            Color(0xFF221015),
            Color(0xFF3E131B),
          ],
        _StudioBrandStyle.dc => const [
            Color(0xFF0D1729),
            Color(0xFF102A56),
          ],
      };

  @override
  Widget build(BuildContext context) {
    final collageItems = items.take(4).toList(growable: false);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 222,
        height: 114,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _gradientColors,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.26),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17.5),
          child: Stack(
            children: [
              // Right side: 3D tilted 2x2 poster fan collage
              Positioned(
                right: -12,
                top: -10,
                bottom: -14,
                width: 120,
                child: Transform.rotate(
                  angle: 0.24,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final v in collageItems)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox(
                            width: 52,
                            height: 66,
                            child: PosterImage(
                              url: v.poster,
                              title: v.title,
                              year: v.year,
                              fit: BoxFit.cover,
                              placeholder: Container(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Smooth left-to-right gradient mask so brand emblem pops crisply
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        _gradientColors.first,
                        _gradientColors.first.withValues(alpha: 0.92),
                        _gradientColors.last.withValues(alpha: 0.22),
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
              ),
              // Left brand identity badge
              Positioned(
                left: 16,
                top: 0,
                bottom: 0,
                width: 112,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildBrandWordmark(),
                    const SizedBox(height: 5),
                    Text(
                      '${items.length} 部精选',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrandWordmark() {
    return switch (style) {
      _StudioBrandStyle.disney => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(68, 12),
              painter: _DisneyArcPainter(),
            ),
            const Text(
              'Disney+',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                height: 1.0,
              ),
            ),
          ],
        ),
      _StudioBrandStyle.marvel => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFE62429),
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text(
            'MARVEL',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
              height: 1.05,
            ),
          ),
        ),
      _StudioBrandStyle.dc => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0476F2),
                border: Border.all(color: Colors.white, width: 2.0),
              ),
              alignment: Alignment.center,
              child: const Text(
                'DC',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '宇宙',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
    };
  }
}

class _DisneyArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x3340C8FF), Color(0xFF7CE8FF), Color(0xFFFFFFFF)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(4, size.height)
      ..quadraticBezierTo(size.width * 0.48, -size.height * 0.35, size.width - 2, size.height * 0.85);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Ref Image 2 Middle: Compact pill with a 3-card fanned mini-poster stack on the
/// left + bold category label on the right (`合家欢`, `热播剧集`, `热门综艺`...).
class _StackedCategoryPill extends StatelessWidget {
  final String label;
  final List<CmsVideo> items;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _StackedCategoryPill({
    required this.label,
    required this.items,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final stack = items.take(3).toList(growable: false);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 58,
        padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
        decoration: BoxDecoration(
          color: palette.isDark
              ? const Color(0xFF1C1F28)
              : palette.groupedPrimary,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: palette.isDark
                ? Colors.white.withValues(alpha: 0.11)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.isDark ? 0.24 : 0.06,
              ),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  for (int i = stack.length - 1; i >= 0; i--)
                    Positioned(
                      left: i * 5.0,
                      top: i * 1.5,
                      bottom: i * 1.5,
                      child: Container(
                        width: 30,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.28),
                            width: 0.7,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5.5),
                          child: PosterImage(
                            url: stack[i].poster,
                            title: stack[i].title,
                            year: stack[i].year,
                            fit: BoxFit.cover,
                            placeholder: Container(
                              color: palette.groupedTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ref Image 2 Bottom: Tall card filled with a 3-row staggered poster-wall mosaic
/// + deep bottom gradient + bold editorial title (`豆瓣高分`, `烂番茄口碑`).
class _PosterWallMosaicCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<CmsVideo> items;
  final Color accentColor;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _PosterWallMosaicCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.accentColor,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pool = items.isEmpty
        ? const <CmsVideo>[]
        : List<CmsVideo>.generate(12, (i) => items[i % items.length]);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 238,
        height: 274,
        decoration: BoxDecoration(
          color: const Color(0xFF15171F),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: palette.isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.isDark ? 0.36 : 0.14,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21.5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 3 staggered rows of mini posters
              Column(
                children: [
                  for (int row = 0; row < 3; row++)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: row == 0 ? 0 : 5,
                          left: row.isOdd ? 12 : 0,
                        ),
                        child: Row(
                          children: [
                            for (int col = 0; col < 4; col++) ...[
                              if (col > 0) const SizedBox(width: 5),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: pool.isEmpty
                                      ? Container(color: const Color(0xFF232630))
                                      : PosterImage(
                                          url: pool[(row * 4 + col) % pool.length].poster,
                                          title: pool[(row * 4 + col) % pool.length].title,
                                          year: pool[(row * 4 + col) % pool.length].year,
                                          fit: BoxFit.cover,
                                          placeholder: Container(
                                            color: const Color(0xFF242731),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              // Deep feathered bottom scrim cradling the bold title
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.05),
                        Colors.black.withValues(alpha: 0.18),
                        const Color(0xE611131B),
                        const Color(0xFF101219),
                      ],
                      stops: const [0.0, 0.45, 0.78, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.68),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.88),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _buildFallbackThumb(String title, ApplePalette palette) {
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: palette.isDark
            ? const [Color(0xFF23252C), Color(0xFF15161B)]
            : const [Color(0xFFE4E8F0), Color(0xFFD7DCE8)],
      ),
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(10),
    child: Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: palette.labelTertiary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
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

    final placeholder = _buildFallbackThumb(video.title, palette);

    return GestureDetector(
      key: Key('curated-poster-${video.id}'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 114,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
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
                  borderRadius: BorderRadius.circular(12.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: video.poster,
                        title: video.title,
                        year: video.year,
                        fit: BoxFit.cover,
                        fadeIn: true,
                        highRes: true,
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

/// Interactive Poster Wall page launched with a 2-phase physics transition:
/// - **Phase 1 (`0.00 -> 0.46`)**: Posters free-fall from above under gravity
///   acceleration with damped elastic bounce, piling into an organic fanned
///   card stack in the center of the viewport (with subtle haptic ticks).
/// - **Phase 2 (`0.46 -> 0.94`)**: Every stacked poster springs outward into
///   its exact cell in the 3-column Poster Wall, unwinding rotation to 0°.
/// - **Phase 3 (`0.88 -> 1.00`)**: Cross-fades seamlessly into the scrollable
///   interactive Poster Wall where tapping any poster opens `DetailScreen`.
class _CuratedGravityWallPage extends StatefulWidget {
  final String title;
  final String subtitle;
  final Color accentColor;
  final List<CmsVideo> items;
  final bool hasUserSources;
  final ValueChanged<CmsVideo> onOpenVideo;

  const _CuratedGravityWallPage({
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.items,
    required this.hasUserSources,
    required this.onOpenVideo,
  });

  @override
  State<_CuratedGravityWallPage> createState() =>
      _CuratedGravityWallPageState();
}

class _CuratedGravityWallPageState extends State<_CuratedGravityWallPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _playedHaptic1 = false;
  bool _playedHaptic2 = false;
  bool _playedHaptic3 = false;
  bool _initialized = false;

  static const int _maxAnimatedCards = 12;
  static const List<double> _stackAngles = [
    -0.21,
    0.16,
    -0.12,
    0.20,
    -0.08,
    0.13,
    -0.17,
    0.09,
    -0.05,
    0.14,
    -0.11,
    0.06,
  ];
  static const List<Offset> _stackJitters = [
    Offset(-16, 12),
    Offset(14, 8),
    Offset(-10, 4),
    Offset(12, 0),
    Offset(-14, -4),
    Offset(8, -7),
    Offset(-6, -10),
    Offset(10, -12),
    Offset(-4, -14),
    Offset(6, -16),
    Offset(-3, -18),
    Offset(2, -20),
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1180),
    )..addListener(_handleAnimationTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final disableAnim = MediaQuery.disableAnimationsOf(context);
    if (disableAnim || widget.items.isEmpty) {
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward(from: 0.0);
    }
  }

  void _handleAnimationTick() {
    final v = _ctrl.value;
    if (!_playedHaptic1 && v >= 0.24) {
      _playedHaptic1 = true;
      HapticFeedback.lightImpact();
    } else if (!_playedHaptic2 && v >= 0.36) {
      _playedHaptic2 = true;
      HapticFeedback.lightImpact();
    } else if (!_playedHaptic3 && v >= 0.50) {
      _playedHaptic3 = true;
      HapticFeedback.selectionClick();
    }
  }

  void _replayAnimation() {
    _playedHaptic1 = false;
    _playedHaptic2 = false;
    _playedHaptic3 = false;
    _ctrl.forward(from: 0.0);
  }

  /// Gravity free-fall (`0..0.72`) + damped floor bounce (`0.72..1.0`).
  static double _gravityFallWithBounce(double u) {
    final t = u.clamp(0.0, 1.0);
    if (t < 0.72) {
      final f = t / 0.72;
      return f * f;
    }
    final b = (t - 0.72) / 0.28;
    // Slight overshoot bounce off the stack deck
    final bounce = math.sin(b * math.pi) * math.exp(-2.2 * b) * 0.085;
    return 1.0 - bounce;
  }

  @override
  void dispose() {
    _ctrl.removeListener(_handleAnimationTick);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final animCount = math.min(widget.items.length, _maxAnimatedCards);

    return Scaffold(
      key: const Key('curated-gravity-wall-page'),
      backgroundColor: palette.background,
      appBar: CupertinoNavigationBar(
        backgroundColor: palette.navBarBg,
        border: Border(
          bottom: BorderSide(
            color: palette.separator,
            width: 0.5,
          ),
        ),
        middle: Text(
          widget.title,
          style: TextStyle(
            color: palette.labelPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: CupertinoButton(
          key: const Key('curated-gravity-replay-btn'),
          padding: EdgeInsets.zero,
          minimumSize: const Size(28, 28),
          onPressed: _replayAnimation,
          child: Icon(
            CupertinoIcons.sparkles,
            size: 18,
            color: widget.accentColor,
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          const hPad = 16.0;
          const topPad = 16.0;
          const crossSpacing = 12.0;
          const mainSpacing = 14.0;
          final crossCount = width >= 620 ? 4 : 3;
          final cellW =
              (width - hPad * 2 - crossSpacing * (crossCount - 1)) / crossCount;
          final cellH = cellW / 0.60;
          final posterH = cellH - 36;

          final stackW = math.min(136.0, width * 0.34);
          final stackH = stackW * 1.48;
          final stackCenterX = (width - stackW) * 0.5;
          final stackCenterY = (height - stackH) * 0.44;

          return AnimatedBuilder(
            animation: _ctrl,
            builder: (context, gridChild) {
              final v = _ctrl.value;
              final gridOpacity =
                  v >= 0.86 ? ((v - 0.86) / 0.14).clamp(0.0, 1.0) : 0.0;
              final overlayVisible = v < 0.995;

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Interactive live 3-column Poster Wall
                  IgnorePointer(
                    ignoring: v < 0.92,
                    child: Opacity(
                      opacity: gridOpacity,
                      child: gridChild,
                    ),
                  ),

                  // Physics Gravity-Drop-Stack -> Spring Fan-Out Overlay
                  if (overlayVisible)
                    IgnorePointer(
                      child: Opacity(
                        opacity: v > 0.90
                            ? (1.0 - ((v - 0.90) / 0.10)).clamp(0.0, 1.0)
                            : 1.0,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Subtle atmospheric radial spotlight behind the pile
                            if (v < 0.62)
                              Positioned.fill(
                                child: Opacity(
                                  opacity: (1.0 - (v / 0.62)).clamp(0.0, 1.0) * 0.32,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: RadialGradient(
                                        center: const Alignment(0, -0.08),
                                        radius: 0.72,
                                        colors: [
                                          widget.accentColor.withValues(alpha: 0.42),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            for (int i = 0; i < animCount; i++)
                              _buildPhysicsCard(
                                index: i,
                                count: animCount,
                                progress: v,
                                video: widget.items[i],
                                crossCount: crossCount,
                                hPad: hPad,
                                topPad: topPad,
                                crossSpacing: crossSpacing,
                                mainSpacing: mainSpacing,
                                cellW: cellW,
                                cellH: cellH,
                                posterH: posterH,
                                stackW: stackW,
                                stackH: stackH,
                                stackCenterX: stackCenterX,
                                stackCenterY: stackCenterY,
                                palette: palette,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
            child: GridView.builder(
              key: const Key('curated-gravity-wall-grid'),
              padding: const EdgeInsets.fromLTRB(
                hPad,
                topPad,
                hPad,
                36,
              ),
              physics: const BouncingScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossCount,
                childAspectRatio: 0.60,
                crossAxisSpacing: crossSpacing,
                mainAxisSpacing: mainSpacing,
              ),
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final v = widget.items[index];
                return _CuratedPosterCard(
                  video: v,
                  accentColor: widget.accentColor,
                  palette: palette,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onOpenVideo(v);
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPhysicsCard({
    required int index,
    required int count,
    required double progress,
    required CmsVideo video,
    required int crossCount,
    required double hPad,
    required double topPad,
    required double crossSpacing,
    required double mainSpacing,
    required double cellW,
    required double cellH,
    required double posterH,
    required double stackW,
    required double stackH,
    required double stackCenterX,
    required double stackCenterY,
    required ApplePalette palette,
  }) {
    final row = index ~/ crossCount;
    final col = index % crossCount;
    final targetLeft = hPad + col * (cellW + crossSpacing);
    final targetTop = topPad + row * (cellH + mainSpacing);

    final jitter = _stackJitters[index % _stackJitters.length];
    final stackLeft = stackCenterX + jitter.dx;
    final stackTop = stackCenterY + jitter.dy;
    final stackAngle = _stackAngles[index % _stackAngles.length];

    double left;
    double top;
    double w;
    double h;
    double angle;
    double opacity = 1.0;

    if (progress < 0.46) {
      // Phase 1: Staggered gravity free-fall into the physical card pile
      final startT = (index / math.max(count, 1)) * 0.20;
      final endT = (startT + 0.24).clamp(0.24, 0.46);
      if (progress <= startT) {
        left = stackLeft + jitter.dx * 1.6;
        top = -stackH - 60.0;
        w = stackW;
        h = stackH;
        angle = stackAngle * 1.5;
        opacity = 0.0;
      } else {
        final localU = ((progress - startT) / (endT - startT)).clamp(0.0, 1.0);
        final fall = _gravityFallWithBounce(localU);
        final startY = -stackH - 40.0 - (index % 3) * 26.0;
        left = stackLeft + jitter.dx * 1.4 * (1.0 - fall);
        top = startY + (stackTop - startY) * fall;
        w = stackW;
        h = stackH;
        angle = stackAngle * (1.45 - 0.45 * fall);
        opacity = (localU * 3.0).clamp(0.0, 1.0);
      }
    } else {
      // Phase 2: Spring fan-out from the pile directly into the 3-col Poster Wall
      final spreadStart = 0.46 + (index / math.max(count, 1)) * 0.09;
      final spreadEnd = (spreadStart + 0.36).clamp(0.70, 0.94);
      final localU =
          ((progress - spreadStart) / (spreadEnd - spreadStart)).clamp(0.0, 1.0);
      final eased = Curves.easeOutBack.transform(localU);
      left = stackLeft + (targetLeft - stackLeft) * eased;
      top = stackTop + (targetTop - stackTop) * eased;
      w = stackW + (cellW - stackW) * eased;
      h = stackH + (posterH - stackH) * eased;
      angle = stackAngle * (1.0 - Curves.easeOutCubic.transform(localU));
    }

    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: angle,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.22),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: progress < 0.46 ? 0.36 : 0.20,
                  ),
                  blurRadius: progress < 0.46 ? 18 : 10,
                  offset: Offset(0, progress < 0.46 ? 10 : 5),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12.5),
              child: PosterImage(
                url: video.poster,
                title: video.title,
                year: video.year,
                fit: BoxFit.cover,
                highRes: true,
                placeholder: _buildFallbackThumb(video.title, palette),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

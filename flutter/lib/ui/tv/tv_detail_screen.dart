// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cms_client.dart';
import '../../core/models.dart';
import '../../core/resilient_http_client.dart';
import '../../core/storage_service.dart';
import '../apple_theme.dart';
import '../netdisk_sheet.dart';
import '../player_screen.dart';
import '../poster_image.dart';
import 'tv_ambient_theme.dart';
import 'tv_focus_widgets.dart';

/// 10-foot living-room Immersive Series Detail & Episode screen for HarmonyOS Smart Screen / TV.
/// Features:
/// - Full-bleed edge-to-edge high-res artwork backdrop with dynamic ambient color extraction
///   and multi-stop editorial left-to-right & vertical cinema gradient scrims
/// - Minimal floating top bar, dramatic left-anchored Hero metadata/CTA stage, and lower
///   frosted-glass play-line & adaptive multi-column episode selection dock
class TvDetailScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo initialVideo;
  final StorageService storage;
  final CmsClient client;

  const TvDetailScreen({
    super.key,
    required this.site,
    required this.initialVideo,
    required this.storage,
    required this.client,
  });

  /// Resolves the Netdisk provider key (`quark` | `uc` | `baidu` | `ali`)
  /// for a playback line or episode, or `null` if it is a direct stream line.
  static String? detectNetdiskDrive(CmsLine line, {CmsEpisode? episode}) {
    String? checkEpisode(CmsEpisode ep) {
      final cp = ep.cloudProvider;
      if (cp != null && cp.isNotEmpty) {
        return cp;
      }
      final shareProvider = ResilientHttpClient.cloudProviderForShare(ep.url);
      if (shareProvider != null && shareProvider.isNotEmpty) {
        return shareProvider;
      }
      final lowerUrl = ep.url.toLowerCase();
      if (lowerUrl.contains('pan.quark.cn')) return 'quark';
      if (lowerUrl.contains('drive.uc.cn')) return 'uc';
      if (lowerUrl.contains('pan.baidu.com')) return 'baidu';
      if (lowerUrl.contains('alipan.com') ||
          lowerUrl.contains('aliyundrive.com')) {
        return 'ali';
      }
      return null;
    }

    if (episode != null) {
      final fromTarget = checkEpisode(episode);
      if (fromTarget != null) return fromTarget;
    }
    for (final ep in line.episodes.take(6)) {
      final fromEp = checkEpisode(ep);
      if (fromEp != null) return fromEp;
    }

    final rawName = line.name.trim();
    final lowerName = rawName.toLowerCase();
    if (rawName.contains('夸父') ||
        rawName.contains('夸克') ||
        lowerName.contains('quark')) {
      return 'quark';
    }
    if (rawName.contains('优汐') ||
        RegExp(r'(?<![a-z])uc(?![a-z])').hasMatch(lowerName)) {
      return 'uc';
    }
    if (rawName.contains('嘟嘟') ||
        rawName.contains('百度') ||
        lowerName.contains('baidu')) {
      return 'baidu';
    }
    if (rawName.contains('阿狸') ||
        rawName.contains('阿里') ||
        lowerName.contains('alipan') ||
        lowerName.contains('aliyundrive')) {
      return 'ali';
    }
    return null;
  }

  static String netdiskDriveLabel(String driveKey) {
    switch (driveKey) {
      case 'quark':
        return '我的夸父（夸克网盘）';
      case 'uc':
        return '我的优汐（UC网盘）';
      case 'baidu':
        return '我的嘟嘟（百度网盘）';
      case 'ali':
        return '我的阿狸（阿里云盘）';
      default:
        return '4K 云盘';
    }
  }

  @override
  State<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends State<TvDetailScreen> {
  static const int _episodesPerGroup = 50;
  static const Color _defaultCinemaBase = Color(0xFF0A0E17);

  late CmsVideo _video;
  bool _loading = true;
  String? _error;
  int _selectedLineIndex = 0;
  int _selectedGroupIndex = 0;
  late bool _descending;
  bool _isFav = false;
  bool _synopsisExpanded = false;
  WatchHistoryEntry? _historyEntry;
  Color? _posterAmbientColor;
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _video = widget.initialVideo;
    _descending = widget.storage.episodesDescending;
    _refreshLocalState();
    _seedImmediateAmbient();
    unawaited(_loadDetail());
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    super.dispose();
  }

  void _seedImmediateAmbient() {
    final immediateBytes = PosterLoader.peekMemory(
      _video.poster,
      title: widget.site.isEffectivelyPrivate ? '' : _video.title,
      year: _video.year,
      preferHd: true,
    );
    if (immediateBytes != null) {
      final cached = PosterLoader.peekAmbientColor(immediateBytes);
      if (cached != null) {
        _posterAmbientColor = cached;
      } else {
        unawaited(_updateAmbientFromBytes(immediateBytes));
      }
    }
  }

  Future<void> _updateAmbientFromBytes(Uint8List bytes) async {
    final extracted = await PosterLoader.extractEdgeAmbientColor(bytes);
    if (!mounted) return;
    if (_posterAmbientColor != extracted) {
      setState(() {
        _posterAmbientColor = extracted;
      });
    }
  }

  Color _resolveCinemaBaseColor() {
    final raw = _posterAmbientColor;
    if (raw == null) return _defaultCinemaBase;
    final hsl = HSLColor.fromColor(raw);
    final deepened = hsl
        .withSaturation((hsl.saturation * 0.62).clamp(0.12, 0.44))
        .withLightness(hsl.lightness.clamp(0.05, 0.11))
        .toColor();
    return Color.lerp(_defaultCinemaBase, deepened, 0.72) ?? _defaultCinemaBase;
  }

  void _refreshLocalState() {
    _isFav = widget.storage.isFavorite(
      widget.site.key,
      _video.id,
      forPrivate: widget.site.isEffectivelyPrivate,
    );
    final history = widget.storage.getWatchHistory(
      forPrivate: widget.site.isEffectivelyPrivate,
    );
    WatchHistoryEntry? matched;
    for (final h in history) {
      if (h.site == widget.site.key && h.id == _video.id) {
        matched = h;
        break;
      }
    }
    _historyEntry = matched;
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await widget.client.fetchDetail(
        widget.site,
        widget.initialVideo,
      );
      if (!mounted) {
        return;
      }
      var initialLine = widget.storage.pickRecommendedLineIndex(fetched.lines);
      var initialGroup = 0;
      final hist = _historyEntry;
      if (hist != null && fetched.lines.isNotEmpty) {
        final matchedLine =
            fetched.lines.indexWhere((l) => l.name == hist.line);
        if (matchedLine >= 0) {
          initialLine = matchedLine;
        }
        final epCount = fetched.lines[initialLine].episodes.length;
        if (epCount > 0) {
          final clampedEp = hist.index.clamp(0, epCount - 1);
          initialGroup = clampedEp ~/ _episodesPerGroup;
        }
      }
      setState(() {
        _video = fetched;
        _selectedLineIndex = initialLine.clamp(
          0,
          math.max(0, fetched.lines.length - 1),
        );
        _selectedGroupIndex = initialGroup;
        _loading = false;
      });
      _seedImmediateAmbient();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openNetdiskManager(String? initialDriveKey) async {
    await showNetdiskAccountSheet(
      context,
      widget.storage,
      initialDriveKey: initialDriveKey,
      onChanged: () {
        if (mounted) {
          setState(() {});
        }
      },
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openPlayer({
    required int lineIndex,
    required int episodeIndex,
    int initialPositionMs = 0,
  }) async {
    if (_video.lines.isEmpty) {
      return;
    }
    final safeLine = lineIndex.clamp(0, _video.lines.length - 1);
    final targetLine = _video.lines[safeLine];
    if (targetLine.episodes.isEmpty) {
      return;
    }
    final safeEp = episodeIndex.clamp(0, targetLine.episodes.length - 1);
    final targetEp = targetLine.episodes[safeEp];

    final driveKey = TvDetailScreen.detectNetdiskDrive(
      targetLine,
      episode: targetEp,
    );
    if (driveKey != null && !widget.storage.isNetdiskLoggedIn(driveKey)) {
      await _openNetdiskManager(driveKey);
      if (!mounted || !widget.storage.isNetdiskLoggedIn(driveKey)) {
        if (mounted) {
          setState(() {});
        }
        return;
      }
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          site: widget.site,
          video: _video,
          initialLineIndex: safeLine,
          initialEpisodeIndex: safeEp,
          initialPositionMs: initialPositionMs,
          storage: widget.storage,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(_refreshLocalState);
  }

  Future<void> _playPrimaryCta() async {
    if (_video.lines.isEmpty) {
      return;
    }
    final hist = _historyEntry;
    if (hist != null) {
      final lineIdx = _video.lines.indexWhere((l) => l.name == hist.line);
      final effectiveLine = lineIdx >= 0 ? lineIdx : _selectedLineIndex;
      await _openPlayer(
        lineIndex: effectiveLine,
        episodeIndex: hist.index,
        initialPositionMs: hist.resumePosition,
      );
      return;
    }
    await _openPlayer(lineIndex: _selectedLineIndex, episodeIndex: 0);
  }

  Future<void> _toggleFav() async {
    final next = await widget.storage.toggleFavorite(widget.site, _video);
    if (!mounted) {
      return;
    }
    setState(() => _isFav = next);
  }

  Future<void> _openFullEpisodeOverlay() async {
    if (_video.lines.isEmpty) return;
    final bgColor = _resolveCinemaBaseColor();
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (ctx, anim, _) => FadeTransition(
          opacity: anim,
          child: _TvImmersiveEpisodeSheet(
            site: widget.site,
            video: _video,
            storage: widget.storage,
            baseColor: bgColor,
            historyEntry: _historyEntry,
            initialLineIndex: _selectedLineIndex,
            initialDescending: _descending,
            onLineChanged: (idx) {
              if (mounted) {
                setState(() {
                  _selectedLineIndex = idx;
                  _selectedGroupIndex = 0;
                });
              }
            },
            onDescendingChanged: (desc) {
              if (mounted) {
                setState(() => _descending = desc);
              }
              unawaited(widget.storage.setEpisodesDescending(desc));
            },
            onOpenNetdisk: _openNetdiskManager,
            onSelectEpisode: (lineIdx, epIdx, resumeMs) {
              Navigator.of(ctx).pop();
              unawaited(
                _openPlayer(
                  lineIndex: lineIdx,
                  episodeIndex: epIdx,
                  initialPositionMs: resumeMs,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatMs(int ms) {
    final totalSec = math.max(0, ms ~/ 1000);
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  int _computeGridColumns(
    double availableWidth,
    List<int> visibleIndices,
    CmsLine activeLine,
  ) {
    var maxLabelLen = 0;
    for (final epIndex in visibleIndices) {
      final len = activeLine.episodes[epIndex].name.trim().length;
      if (len > maxLabelLen) maxLabelLen = len;
    }
    if (visibleIndices.length <= 8 || maxLabelLen >= 10) {
      return availableWidth >= 1100 ? 4 : 3;
    }
    if (availableWidth >= 1450) return 6;
    if (availableWidth >= 1080) return 5;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _video.lines;
    final activeLine = lines.isNotEmpty
        ? lines[_selectedLineIndex.clamp(0, lines.length - 1)]
        : null;
    final totalEpisodes = activeLine?.episodes.length ?? 0;
    final groupCount = totalEpisodes > 0
        ? ((totalEpisodes + _episodesPerGroup - 1) ~/ _episodesPerGroup)
        : 0;
    final safeGroup =
        groupCount > 0 ? _selectedGroupIndex.clamp(0, groupCount - 1) : 0;

    final episodeIndices = <int>[];
    if (totalEpisodes > 0) {
      final start = safeGroup * _episodesPerGroup;
      final end = math.min(totalEpisodes, start + _episodesPerGroup);
      for (var i = start; i < end; i++) {
        episodeIndices.add(i);
      }
      if (_descending) {
        episodeIndices.sort((a, b) => b.compareTo(a));
      }
    }

    final hist = _historyEntry;
    final primaryCtaLabel = hist != null
        ? '续播 ${hist.episode.isNotEmpty ? hist.episode : "第${hist.index + 1}集"} (${_formatMs(hist.resumePosition)})'
        : '立即播放';
    final hasAnyNetdiskLine =
        lines.any((l) => TvDetailScreen.detectNetdiskDrive(l) != null);
    final activeDriveKey = activeLine != null
        ? TvDetailScreen.detectNetdiskDrive(activeLine)
        : null;
    final activeLineNeedsAuth = activeDriveKey != null &&
        !widget.storage.isNetdiskLoggedIn(activeDriveKey);

    final targetBg = _resolveCinemaBaseColor();
    final screenSize = MediaQuery.sizeOf(context);
    final topHeroBreathing =
        (screenSize.height * 0.12).clamp(48.0, 128.0);
    final horizontalPad =
        (screenSize.width * 0.036).clamp(36.0, 64.0);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(begin: targetBg, end: targetBg),
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        builder: (context, animatedBg, _) {
          final bgColor = animatedBg ?? targetBg;
          return Scaffold(
            backgroundColor: bgColor,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Layer 0: Full-bleed atmospheric artwork backdrop + multi-layer scrims
                _ImmersiveTvBackdrop(
                  posterUrl: _video.poster,
                  title: widget.site.isEffectivelyPrivate ? '' : _video.title,
                  year: _video.year,
                  baseColor: bgColor,
                  themeId: widget.storage.tvAmbientTheme,
                  intensity: widget.storage.tvAmbientIntensity,
                  scrollOffset: _scrollOffset,
                  onBytesLoaded: _updateAmbientFromBytes,
                ),

                // Layer 1: Scrollable immersive foreground stage
                SafeArea(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.axis == Axis.vertical) {
                        final next =
                            notification.metrics.pixels.clamp(0.0, 420.0);
                        if ((_scrollOffset.value - next).abs() > 0.5) {
                          _scrollOffset.value = next;
                        }
                      }
                      return false;
                    },
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPad,
                        24,
                        horizontalPad,
                        40,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Minimal floating top chrome
                          Row(
                            children: [
                              TvFocusPill(
                                glass: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 10,
                                ),
                                onSelect: () =>
                                    Navigator.of(context).maybePop(),
                                child: const Text(
                                  '← 返回',
                                  style: TextStyle(fontSize: 15),
                                ),
                              ),
                              const Spacer(),
                              const MarcoBrandLogo(iconSize: 34, fontSize: 20),
                            ],
                          ),

                          SizedBox(height: topHeroBreathing),

                          // Editorial left-anchored Hero Stage
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 880),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    _metaChip(
                                      widget.site.name,
                                      highlight: true,
                                    ),
                                    if (_video.doubanScore != null &&
                                        _video.doubanScore! > 0)
                                      _goldScoreChip(
                                        '豆瓣 ${_video.doubanScore!.toStringAsFixed(1)}',
                                      ),
                                    if (_video.year.isNotEmpty)
                                      _metaChip(_video.year),
                                    if (_video.area.isNotEmpty)
                                      _metaChip(_video.area),
                                    if (_video.remarks.isNotEmpty)
                                      _metaChip(_video.remarks),
                                    if (activeDriveKey != null)
                                      _amberBadgeChip('4K 云盘原画'),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  _video.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 44,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.7,
                                    height: 1.14,
                                    shadows: [
                                      Shadow(
                                        color: Color(0xBA000000),
                                        blurRadius: 22,
                                        offset: Offset(0, 6),
                                      ),
                                    ],
                                  ),
                                ),
                                if (hist != null) ...[
                                  const SizedBox(height: 12),
                                  _buildHistoryProgressBadge(hist),
                                ],
                                if (_video.actor.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    '主演：${_video.actor}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.78),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                                if (_video.description.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  GestureDetector(
                                    onTap: () => setState(
                                      () => _synopsisExpanded =
                                          !_synopsisExpanded,
                                    ),
                                    child: Text(
                                      _video.description,
                                      maxLines: _synopsisExpanded ? 6 : 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color:
                                            Colors.white.withValues(alpha: 0.84),
                                        fontSize: 16,
                                        height: 1.52,
                                        shadows: const [
                                          Shadow(
                                            color: Color(0x88000000),
                                            blurRadius: 10,
                                            offset: Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 24),

                                // Hero Horizontal Action Pill Row
                                Wrap(
                                  spacing: 14,
                                  runSpacing: 12,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    TvFocusPill(
                                      autofocus: true,
                                      prominent: true,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 28,
                                        vertical: 14,
                                      ),
                                      onSelect: lines.isEmpty
                                          ? null
                                          : _playPrimaryCta,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            CupertinoIcons.play_fill,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            primaryCtaLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 17),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (totalEpisodes > 1)
                                      TvFocusPill(
                                        glass: true,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 22,
                                          vertical: 14,
                                        ),
                                        onSelect: _openFullEpisodeOverlay,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              CupertinoIcons.square_grid_2x2,
                                              size: 16,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '选集 · 共$totalEpisodes集',
                                              style:
                                                  const TextStyle(fontSize: 16),
                                            ),
                                          ],
                                        ),
                                      ),
                                    TvFocusPill(
                                      glass: true,
                                      selected: _isFav,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 22,
                                        vertical: 14,
                                      ),
                                      onSelect: _toggleFav,
                                      child: Text(
                                        _isFav ? '★ 已收藏' : '☆ 收藏',
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ),
                                    if (hasAnyNetdiskLine)
                                      TvFocusPill(
                                        glass: true,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 14,
                                        ),
                                        onSelect: () =>
                                            _openNetdiskManager(activeDriveKey),
                                        child: const Text(
                                          '☁️ 云盘扫码管理',
                                          style: TextStyle(fontSize: 15),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 34),

                          // Lower Frosted-Glass Play-Line & Episode Panel
                          _buildLowerGlassPanel(
                            lines: lines,
                            activeLine: activeLine,
                            activeDriveKey: activeDriveKey,
                            activeLineNeedsAuth: activeLineNeedsAuth,
                            totalEpisodes: totalEpisodes,
                            groupCount: groupCount,
                            safeGroup: safeGroup,
                            episodeIndices: episodeIndices,
                            hist: hist,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHistoryProgressBadge(WatchHistoryEntry hist) {
    final hasDuration = hist.duration > 0;
    final frac = hasDuration
        ? (hist.position / hist.duration).clamp(0.0, 1.0)
        : 0.0;
    final epLabel =
        hist.episode.isNotEmpty ? hist.episode : '第${hist.index + 1}集';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: AppleColors.systemBlue,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '上次观看：$epLabel · ${_formatMs(hist.resumePosition)}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.90),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (hasDuration && frac > 0.01) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 4,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppleColors.systemBlue,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildLowerGlassPanel({
    required List<CmsLine> lines,
    required CmsLine? activeLine,
    required String? activeDriveKey,
    required bool activeLineNeedsAuth,
    required int totalEpisodes,
    required int groupCount,
    required int safeGroup,
    required List<int> episodeIndices,
    required WatchHistoryEntry? hist,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(26, 22, 26, 26),
      decoration: BoxDecoration(
        color: const Color(0xB80E1420),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 32,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading && lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 42),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CupertinoActivityIndicator(radius: 14),
                    SizedBox(width: 12),
                    Text(
                      '正在解析选集与播放线路…',
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
            )
          else if (_error != null && lines.isEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '加载详情失败：$_error',
                    style: const TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                TvFocusPill(
                  glass: true,
                  onSelect: _loadDetail,
                  child: const Text('重试加载'),
                ),
              ],
            )
          else if (lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '当前条目暂无可播放线路',
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 15,
                ),
              ),
            )
          else ...[
            // Play-Line selector row
            Row(
              children: [
                const Text(
                  '播放线路',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          for (var i = 0; i < lines.length; i++)
                            Builder(
                              builder: (_) {
                                final driveKey =
                                    TvDetailScreen.detectNetdiskDrive(lines[i]);
                                return Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: TvFocusPill(
                                    glass: true,
                                    selected: i == _selectedLineIndex,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 9,
                                    ),
                                    onSelect: () {
                                      setState(() {
                                        _selectedLineIndex = i;
                                        _selectedGroupIndex = 0;
                                      });
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${lines[i].name} (${lines[i].episodes.length})',
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                        if (driveKey != null) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xCC1E1506),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: const Color(0xE6F5A623),
                                              ),
                                            ),
                                            child: const Text(
                                              '4K 云盘',
                                              style: TextStyle(
                                                color: Color(0xFFFFD166),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ] else ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0x3834C759),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: const Color(0x8834C759),
                                              ),
                                            ),
                                            child: const Text(
                                              'HLS',
                                              style: TextStyle(
                                                color: Color(0xFF7CF0A4),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),

            if (activeLineNeedsAuth && activeDriveKey != null) ...[
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: const Color(0x22F5A623),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x55F5A623)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.cloud_fill,
                      color: Color(0xFFFFCA58),
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '当前线路需登录「${TvDetailScreen.netdiskDriveLabel(activeDriveKey)}」以启用 4K 原画直连播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    TvFocusPill(
                      glass: true,
                      selected: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 7,
                      ),
                      onSelect: () => _openNetdiskManager(activeDriveKey),
                      child: const Text(
                        '立即扫码登录',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.10),
              ),
            ),

            // Episode toolbar
            Row(
              children: [
                Text(
                  '选集列表（共 $totalEpisodes 集）',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 14),
                TvFocusPill(
                  glass: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  onSelect: () {
                    final next = !_descending;
                    setState(() => _descending = next);
                    unawaited(widget.storage.setEpisodesDescending(next));
                  },
                  child: Text(
                    _descending ? '↓ 倒序' : '↑ 正序',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 10),
                if (groupCount > 1)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var g = 0; g < groupCount; g++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: TvFocusPill(
                                glass: true,
                                selected: g == safeGroup,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 7,
                                ),
                                onSelect: () =>
                                    setState(() => _selectedGroupIndex = g),
                                child: Text(
                                  '${g * _episodesPerGroup + 1}-${math.min(totalEpisodes, (g + 1) * _episodesPerGroup)}',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  )
                else
                  const Spacer(),
                if (totalEpisodes > 12) ...[
                  const SizedBox(width: 10),
                  TvFocusPill(
                    glass: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    onSelect: _openFullEpisodeOverlay,
                    child: const Text(
                      '全屏选集 ›',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // Adaptive ergonomic episode grid (fixed crisp tile height!)
            if (activeLine != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = _computeGridColumns(
                    constraints.maxWidth,
                    episodeIndices,
                    activeLine,
                  );
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: episodeIndices.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 76,
                    ),
                    itemBuilder: (context, idx) {
                      final epIndex = episodeIndices[idx];
                      final ep = activeLine.episodes[epIndex];
                      final isWatchedEp = hist != null &&
                          hist.line == activeLine.name &&
                          hist.index == epIndex;
                      final progress = (isWatchedEp && hist.duration > 0)
                          ? (hist.position / hist.duration).clamp(0.0, 1.0)
                          : 0.0;
                      return _TvImmersiveEpisodeTile(
                        episodeNumber: epIndex + 1,
                        title: ep.name,
                        isWatched: isWatchedEp,
                        progressFraction: progress,
                        isNetdiskLine: activeDriveKey != null,
                        onSelect: () => _openPlayer(
                          lineIndex: _selectedLineIndex,
                          episodeIndex: epIndex,
                          initialPositionMs:
                              isWatchedEp ? hist.resumePosition : 0,
                        ),
                      );
                    },
                  );
                },
              ),
          ],
        ],
      ),
    );
  }

  Widget _metaChip(String label, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: highlight
            ? AppleColors.systemBlue.withValues(alpha: 0.28)
            : Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlight
              ? AppleColors.systemBlue.withValues(alpha: 0.65)
              : Colors.white.withValues(alpha: 0.20),
          width: 0.9,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: highlight ? const Color(0xFFD6EAFF) : Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _goldScoreChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF5C443),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF0A0F18),
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _amberBadgeChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x38F5A623),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xCCF5A623)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFFFCA58),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Full-bleed atmospheric artwork backdrop with editorial left-to-right & vertical
/// gradient scrims and scroll-responsive deepening veil.
class _ImmersiveTvBackdrop extends StatelessWidget {
  final String posterUrl;
  final String title;
  final String year;
  final Color baseColor;
  final String themeId;
  final String intensity;
  final ValueNotifier<double> scrollOffset;
  final ValueChanged<Uint8List>? onBytesLoaded;
  final bool softened;

  const _ImmersiveTvBackdrop({
    required this.posterUrl,
    required this.title,
    required this.year,
    required this.baseColor,
    this.themeId = 'aurora',
    this.intensity = 'standard',
    required this.scrollOffset,
    this.onBytesLoaded,
    this.softened = false,
  });

  Widget _fallbackAmbientOrbs() {
    return TvAmbientSoftGlowBackground(
      themeId: themeId,
      intensity: intensity,
      posterSync: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = posterUrl.trim();
    final artwork = trimmed.isNotEmpty
        ? PosterImage(
            url: trimmed,
            title: title,
            year: year,
            highRes: true,
            fit: BoxFit.cover,
            alignment: const Alignment(0.28, -0.22),
            onBytesLoaded: onBytesLoaded,
            placeholder: _fallbackAmbientOrbs(),
          )
        : _fallbackAmbientOrbs();

    final renderedArtwork = softened
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: 14,
              sigmaY: 14,
              tileMode: TileMode.decal,
            ),
            child: artwork,
          )
        : artwork;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: baseColor),
        Positioned.fill(child: renderedArtwork),
        // Left-to-right editorial scrim keeping right artwork vibrant while left copy pops
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: softened
                  ? [
                      baseColor.withValues(alpha: 0.86),
                      baseColor.withValues(alpha: 0.68),
                      baseColor.withValues(alpha: 0.44),
                    ]
                  : [
                      baseColor.withValues(alpha: 0.96),
                      baseColor.withValues(alpha: 0.86),
                      baseColor.withValues(alpha: 0.48),
                      baseColor.withValues(alpha: 0.16),
                      baseColor.withValues(alpha: 0.08),
                    ],
              stops: softened
                  ? const [0.0, 0.5, 1.0]
                  : const [0.0, 0.28, 0.54, 0.78, 1.0],
            ),
          ),
        ),
        // Top & bottom cinema vignette melting seamlessly into the lower dock
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: softened
                  ? [
                      baseColor.withValues(alpha: 0.42),
                      baseColor.withValues(alpha: 0.68),
                      baseColor.withValues(alpha: 0.94),
                    ]
                  : [
                      baseColor.withValues(alpha: 0.56),
                      baseColor.withValues(alpha: 0.08),
                      baseColor.withValues(alpha: 0.24),
                      baseColor.withValues(alpha: 0.82),
                      baseColor.withValues(alpha: 0.97),
                    ],
              stops: softened
                  ? const [0.0, 0.42, 1.0]
                  : const [0.0, 0.20, 0.48, 0.72, 1.0],
            ),
          ),
        ),
        // Smooth scroll-responsive deepening veil
        ValueListenableBuilder<double>(
          valueListenable: scrollOffset,
          builder: (context, offset, _) {
            final alpha = (offset / 320.0).clamp(0.0, 1.0) * 0.44;
            if (alpha <= 0.01) return const SizedBox.shrink();
            return ColoredBox(color: baseColor.withValues(alpha: alpha));
          },
        ),
      ],
    );
  }
}

/// Structured 10-foot episode card tile with focus-aware contrast, episode index badge,
/// last-watched status tag, and embedded progress bar.
class _TvImmersiveEpisodeTile extends StatefulWidget {
  final int episodeNumber;
  final String title;
  final bool isWatched;
  final double progressFraction;
  final bool isNetdiskLine;
  final bool autofocus;
  final VoidCallback onSelect;

  const _TvImmersiveEpisodeTile({
    required this.episodeNumber,
    required this.title,
    required this.isWatched,
    required this.progressFraction,
    required this.isNetdiskLine,
    this.autofocus = false,
    required this.onSelect,
  });

  @override
  State<_TvImmersiveEpisodeTile> createState() =>
      _TvImmersiveEpisodeTileState();
}

class _TvImmersiveEpisodeTileState extends State<_TvImmersiveEpisodeTile> {
  bool _focused = false;
  bool _hovered = false;

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    final highlighted = _focused || _hovered;
    final bg = highlighted
        ? Colors.white
        : (widget.isWatched
            ? AppleColors.systemBlue.withValues(alpha: 0.28)
            : Colors.white.withValues(alpha: 0.08));
    final borderColor = _focused
        ? Colors.white
        : (widget.isWatched
            ? AppleColors.systemBlue.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.16));
    final primaryFg = highlighted ? const Color(0xFF0A0F18) : Colors.white;
    final mutedFg = highlighted
        ? const Color(0xFF3E4A5C)
        : Colors.white.withValues(alpha: 0.62);
    final indexLabel =
        'EP ${widget.episodeNumber.toString().padLeft(2, '0')}';

    return Semantics(
      button: true,
      selected: widget.isWatched,
      label: widget.title,
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused) _ensureVisible();
        },
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && isTvActivationKey(event.logicalKey)) {
            widget.onSelect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: AnimatedScale(
              scale: _focused ? 1.04 : 1.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: borderColor,
                    width: _focused ? 2.4 : (widget.isWatched ? 1.4 : 1.0),
                  ),
                  boxShadow: _focused
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.46),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        if (widget.isWatched) ...[
                          Icon(
                            CupertinoIcons.play_fill,
                            size: 11,
                            color: highlighted
                                ? AppleColors.systemBlue
                                : const Color(0xFF7EC0FF),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          indexLabel,
                          style: TextStyle(
                            color: mutedFg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const Spacer(),
                        if (widget.isWatched)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: highlighted
                                  ? AppleColors.systemBlue
                                  : AppleColors.systemBlue
                                      .withValues(alpha: 0.40),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              '上次观看',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else if (widget.isNetdiskLine)
                          Text(
                            '4K',
                            style: TextStyle(
                              color: highlighted
                                  ? const Color(0xFFB56E00)
                                  : const Color(0xFFFFCA58),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                      ],
                    ),
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: primaryFg,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.isWatched && widget.progressFraction > 0.01)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: widget.progressFraction,
                          minHeight: 3,
                          backgroundColor: highlighted
                              ? Colors.black.withValues(alpha: 0.14)
                              : Colors.white.withValues(alpha: 0.18),
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
        ),
      ),
    );
  }
}

/// Full-screen immersive episode browser overlay for HarmonyOS Smart Screen.
class _TvImmersiveEpisodeSheet extends StatefulWidget {
  final CmsSite site;
  final CmsVideo video;
  final StorageService storage;
  final Color baseColor;
  final WatchHistoryEntry? historyEntry;
  final int initialLineIndex;
  final bool initialDescending;
  final ValueChanged<int> onLineChanged;
  final ValueChanged<bool> onDescendingChanged;
  final Future<void> Function(String? driveKey) onOpenNetdisk;
  final void Function(int lineIdx, int epIdx, int resumeMs) onSelectEpisode;

  const _TvImmersiveEpisodeSheet({
    required this.site,
    required this.video,
    required this.storage,
    required this.baseColor,
    required this.historyEntry,
    required this.initialLineIndex,
    required this.initialDescending,
    required this.onLineChanged,
    required this.onDescendingChanged,
    required this.onOpenNetdisk,
    required this.onSelectEpisode,
  });

  @override
  State<_TvImmersiveEpisodeSheet> createState() =>
      _TvImmersiveEpisodeSheetState();
}

class _TvImmersiveEpisodeSheetState extends State<_TvImmersiveEpisodeSheet> {
  static const int _sheetPageSize = 20;

  late int _lineIndex;
  late bool _descending;
  int _pageIndex = 0;
  final ValueNotifier<double> _scrollOffset = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _lineIndex = widget.initialLineIndex.clamp(
      0,
      math.max(0, widget.video.lines.length - 1),
    );
    _descending = widget.initialDescending;
    final hist = widget.historyEntry;
    if (hist != null && widget.video.lines.isNotEmpty) {
      final activeLine = widget.video.lines[_lineIndex];
      if (hist.line == activeLine.name && activeLine.episodes.isNotEmpty) {
        final clamped = hist.index.clamp(0, activeLine.episodes.length - 1);
        final visualPos =
            _descending ? (activeLine.episodes.length - 1 - clamped) : clamped;
        _pageIndex = visualPos ~/ _sheetPageSize;
      }
    }
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.video.lines;
    final activeLine = lines.isNotEmpty
        ? lines[_lineIndex.clamp(0, lines.length - 1)]
        : null;
    final total = activeLine?.episodes.length ?? 0;
    final pageCount =
        total > 0 ? ((total + _sheetPageSize - 1) ~/ _sheetPageSize) : 0;
    final safePage =
        pageCount > 0 ? _pageIndex.clamp(0, pageCount - 1) : 0;

    final allIndices = List<int>.generate(total, (i) => i);
    if (_descending) {
      allIndices.sort((a, b) => b.compareTo(a));
    }
    final start = math.min(safePage * _sheetPageSize, allIndices.length);
    final end = math.min(start + _sheetPageSize, allIndices.length);
    final pageIndices = allIndices.sublist(start, end);
    final activeDriveKey = activeLine != null
        ? TvDetailScreen.detectNetdiskDrive(activeLine)
        : null;
    final hist = widget.historyEntry;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        backgroundColor: widget.baseColor,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _ImmersiveTvBackdrop(
              posterUrl: widget.video.poster,
              title: widget.site.isEffectivelyPrivate ? '' : widget.video.title,
              year: widget.video.year,
              baseColor: widget.baseColor,
              themeId: widget.storage.tvAmbientTheme,
              intensity: widget.storage.tvAmbientIntensity,
              scrollOffset: _scrollOffset,
              softened: true,
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(56, 28, 56, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        TvFocusPill(
                          glass: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          onSelect: () => Navigator.of(context).maybePop(),
                          child: const Text(
                            '← 返回详情',
                            style: TextStyle(fontSize: 15),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.video.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                '选集 · 共 $total 集${activeLine != null ? " · ${activeLine.name}" : ""}',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.72),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TvFocusPill(
                          glass: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          onSelect: () {
                            final next = !_descending;
                            setState(() {
                              _descending = next;
                              _pageIndex = 0;
                            });
                            widget.onDescendingChanged(next);
                          },
                          child: Text(
                            _descending ? '↓ 倒序' : '↑ 正序',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        if (lines.any(
                          (l) => TvDetailScreen.detectNetdiskDrive(l) != null,
                        )) ...[
                          const SizedBox(width: 10),
                          TvFocusPill(
                            glass: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            onSelect: () =>
                                widget.onOpenNetdisk(activeDriveKey),
                            child: const Text(
                              '☁️ 云盘扫码管理',
                              style: TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Spacer(),
                    // Bottom-anchored frosted glass episode panel (hugs content cleanly so upper artwork breathes!)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(26),
                        decoration: BoxDecoration(
                          color: const Color(0xC20D121D),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.16),
                            width: 1.1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.48),
                              blurRadius: 34,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Line pills
                            Row(
                              children: [
                                Text(
                                  '播放线路',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.78),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          for (var i = 0; i < lines.length; i++)
                                            Builder(
                                              builder: (_) {
                                                final lineDrive =
                                                    TvDetailScreen
                                                        .detectNetdiskDrive(
                                                  lines[i],
                                                );
                                                return Padding(
                                                  padding: const EdgeInsets.only(
                                                    right: 10,
                                                  ),
                                                  child: TvFocusPill(
                                                    glass: true,
                                                    selected: i == _lineIndex,
                                                    onSelect: () {
                                                      setState(() {
                                                        _lineIndex = i;
                                                        _pageIndex = 0;
                                                      });
                                                      widget.onLineChanged(i);
                                                    },
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          '${lines[i].name} (${lines[i].episodes.length})',
                                                          style:
                                                              const TextStyle(
                                                            fontSize: 14,
                                                          ),
                                                        ),
                                                        if (lineDrive !=
                                                            null) ...[
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 7,
                                                              vertical: 2,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: const Color(
                                                                0xCC1E1506,
                                                              ),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                6,
                                                              ),
                                                              border: Border.all(
                                                                color:
                                                                    const Color(
                                                                  0xE6F5A623,
                                                                ),
                                                              ),
                                                            ),
                                                            child: const Text(
                                                              '4K 云盘',
                                                              style: TextStyle(
                                                                color: Color(
                                                                  0xFFFFD166,
                                                                ),
                                                                fontSize: 11,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                            ),
                                                          ),
                                                        ] else ...[
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 7,
                                                              vertical: 2,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: const Color(
                                                                0x3834C759,
                                                              ),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                6,
                                                              ),
                                                              border: Border.all(
                                                                color:
                                                                    const Color(
                                                                  0x8834C759,
                                                                ),
                                                              ),
                                                            ),
                                                            child: const Text(
                                                              'HLS',
                                                              style: TextStyle(
                                                                color: Color(
                                                                  0xFF7CF0A4,
                                                                ),
                                                                fontSize: 11,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (pageCount > 1) ...[
                              const SizedBox(height: 14),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (var p = 0; p < pageCount; p++)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 8),
                                        child: TvFocusPill(
                                          glass: true,
                                          selected: p == safePage,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 15,
                                            vertical: 7,
                                          ),
                                          onSelect: () =>
                                              setState(() => _pageIndex = p),
                                          child: Text(
                                            '${p * _sheetPageSize + 1}-${math.min(total, (p + 1) * _sheetPageSize)}',
                                            style:
                                                const TextStyle(fontSize: 13),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Divider(
                                height: 1,
                                color: Colors.white.withValues(alpha: 0.10),
                              ),
                            ),
                            if (activeLine != null)
                              Flexible(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    var maxLen = 0;
                                    for (final i in pageIndices) {
                                      final len = activeLine
                                          .episodes[i].name.trim().length;
                                      if (len > maxLen) maxLen = len;
                                    }
                                    final cols =
                                        (pageIndices.length <= 8 || maxLen >= 10)
                                            ? 4
                                            : 5;
                                    return GridView.builder(
                                      shrinkWrap: true,
                                      padding: const EdgeInsets.all(6),
                                      itemCount: pageIndices.length,
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: cols,
                                        mainAxisSpacing: 14,
                                        crossAxisSpacing: 14,
                                        mainAxisExtent: 86,
                                      ),
                                      itemBuilder: (context, idx) {
                                        final epIdx = pageIndices[idx];
                                        final ep = activeLine.episodes[epIdx];
                                        final isWatched = hist != null &&
                                            hist.line == activeLine.name &&
                                            hist.index == epIdx;
                                        final progress =
                                            (isWatched && hist.duration > 0)
                                                ? (hist.position /
                                                        hist.duration)
                                                    .clamp(0.0, 1.0)
                                                : 0.0;
                                        return _TvImmersiveEpisodeTile(
                                          episodeNumber: epIdx + 1,
                                          title: ep.name,
                                          isWatched: isWatched,
                                          progressFraction: progress,
                                          isNetdiskLine: activeDriveKey != null,
                                          autofocus: isWatched ||
                                              (idx == 0 && hist == null),
                                          onSelect: () =>
                                              widget.onSelectEpisode(
                                            _lineIndex,
                                            epIdx,
                                            isWatched ? hist.resumePosition : 0,
                                          ),
                                        );
                                      },
                                    );
                                  },
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
          ],
        ),
      ),
    );
  }
}

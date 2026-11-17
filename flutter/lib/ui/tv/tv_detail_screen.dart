// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;

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
import 'tv_focus_widgets.dart';

/// 10-foot living-room Detail & Episode Grid screen for HarmonyOS Smart Screen / TV.
/// Layout: Left fixed HD poster & primary remote actions; Right independent scrolling
/// synopsis, line selector pills, 50-episode group tabs, asc/desc toggle, and episode grid.
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
    if (rawName.contains('夸父') || rawName.contains('夸克') || lowerName.contains('quark')) {
      return 'quark';
    }
    if (rawName.contains('优汐') ||
        RegExp(r'(?<![a-z])uc(?![a-z])').hasMatch(lowerName)) {
      return 'uc';
    }
    if (rawName.contains('嘟嘟') || rawName.contains('百度') || lowerName.contains('baidu')) {
      return 'baidu';
    }
    if (rawName.contains('阿狸') || rawName.contains('阿里') || lowerName.contains('alipan') || lowerName.contains('aliyundrive')) {
      return 'ali';
    }
    return null;
  }

  @override
  State<TvDetailScreen> createState() => _TvDetailScreenState();
}

class _TvDetailScreenState extends State<TvDetailScreen> {
  static const int _episodesPerGroup = 50;

  late CmsVideo _video;
  bool _loading = true;
  String? _error;
  int _selectedLineIndex = 0;
  int _selectedGroupIndex = 0;
  late bool _descending;
  bool _isFav = false;
  WatchHistoryEntry? _historyEntry;

  @override
  void initState() {
    super.initState();
    _video = widget.initialVideo;
    _descending = widget.storage.episodesDescending;
    _refreshLocalState();
    unawaited(_loadDetail());
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
      final fetched = await widget.client.fetchDetail(widget.site, widget.initialVideo);
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
    final safeEp =
        episodeIndex.clamp(0, targetLine.episodes.length - 1);
    final targetEp = targetLine.episodes[safeEp];

    final driveKey = TvDetailScreen.detectNetdiskDrive(
      targetLine,
      episode: targetEp,
    );
    if (driveKey != null && !widget.storage.isNetdiskLoggedIn(driveKey)) {
      await showNetdiskAccountSheet(
        context,
        widget.storage,
        initialDriveKey: driveKey,
        onChanged: () {
          if (mounted) {
            setState(() {});
          }
        },
      );
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

  String _formatMs(int ms) {
    final totalSec = math.max(0, ms ~/ 1000);
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
        ? '▶ 续播 ${hist.episode.isNotEmpty ? hist.episode : "第${hist.index + 1}集"} (${_formatMs(hist.resumePosition)})'
        : '▶ 立即播放';

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0C0E14),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left fixed poster & primary action column
                SizedBox(
                  width: 280,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: 2 / 3,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: PosterImage(
                            url: _video.poster,
                            title: _video.title,
                            year: _video.year,
                            highRes: true,
                            placeholder: Container(
                              color: const Color(0xFF1D1F26),
                              alignment: Alignment.center,
                              child: const Icon(
                                CupertinoIcons.film,
                                color: Colors.white24,
                                size: 48,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      TvFocusPill(
                        autofocus: true,
                        selected: true,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        onSelect: lines.isEmpty ? null : _playPrimaryCta,
                        child: Center(
                          child: Text(
                            primaryCtaLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TvFocusPill(
                              selected: _isFav,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              onSelect: _toggleFav,
                              child: Center(
                                child: Text(_isFav ? '★ 已收藏' : '☆ 收藏'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TvFocusPill(
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              onSelect: () => Navigator.of(context).maybePop(),
                              child: const Center(child: Text('← 返回')),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 36),
                // Right scrollable metadata & episode selection column
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _video.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            _metaChip(widget.site.name),
                            if (_video.year.isNotEmpty) _metaChip(_video.year),
                            if (_video.area.isNotEmpty) _metaChip(_video.area),
                            if (_video.remarks.isNotEmpty)
                              _metaChip(_video.remarks),
                            if (_video.doubanScore != null &&
                                _video.doubanScore! > 0)
                              _metaChip(
                                '豆瓣 ${_video.doubanScore!.toStringAsFixed(1)}',
                              ),
                          ],
                        ),
                        if (_video.actor.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            '主演：${_video.actor}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                        if (_video.description.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _video.description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 14,
                              height: 1.45,
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        if (_loading && lines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: CupertinoActivityIndicator(radius: 16),
                            ),
                          )
                        else if (_error != null && lines.isEmpty)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '加载详情失败：$_error',
                                style: const TextStyle(
                                  color: AppleColors.systemRed,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TvFocusPill(
                                onSelect: _loadDetail,
                                child: const Text('重试加载'),
                              ),
                            ],
                          )
                        else if (lines.isEmpty)
                          const Text(
                            '当前条目暂无可播放线路',
                            style: TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 15,
                            ),
                          )
                        else ...[
                          Row(
                            children: [
                              const Text(
                                '播放线路',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (lines.any(
                                (l) => TvDetailScreen.detectNetdiskDrive(l) != null,
                              )) ...[
                                const SizedBox(width: 14),
                                TvFocusPill(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  onSelect: () async {
                                    final activeDrive = activeLine != null
                                        ? TvDetailScreen.detectNetdiskDrive(
                                            activeLine,
                                          )
                                        : null;
                                    await showNetdiskAccountSheet(
                                      context,
                                      widget.storage,
                                      initialDriveKey: activeDrive,
                                      onChanged: () {
                                        if (mounted) {
                                          setState(() {});
                                        }
                                      },
                                    );
                                    if (mounted) {
                                      setState(() {});
                                    }
                                  },
                                  child: const Text(
                                    '☁️ 云盘扫码管理',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (var i = 0; i < lines.length; i++)
                                  Builder(
                                    builder: (_) {
                                      final driveKey =
                                          TvDetailScreen.detectNetdiskDrive(
                                            lines[i],
                                          );
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          right: 10,
                                        ),
                                        child: TvFocusPill(
                                          selected: i == _selectedLineIndex,
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
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                ),
                                              ),
                                              if (driveKey != null) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0x33F5A623,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xCCF5A623,
                                                      ),
                                                    ),
                                                  ),
                                                  child: const Text(
                                                    '4K 云盘',
                                                    style: TextStyle(
                                                      color: Color(0xFFFFCA58),
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
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
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              const Text(
                                '选集列表',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 16),
                              TvFocusPill(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 7,
                                ),
                                onSelect: () {
                                  final next = !_descending;
                                  setState(() => _descending = next);
                                  unawaited(
                                    widget.storage.setEpisodesDescending(next),
                                  );
                                },
                                child: Text(
                                  _descending ? '↓ 倒序' : '↑ 正序',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (groupCount > 1)
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        for (var g = 0; g < groupCount; g++)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: TvFocusPill(
                                              selected: g == safeGroup,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 7,
                                                  ),
                                              onSelect: () => setState(
                                                () => _selectedGroupIndex = g,
                                              ),
                                              child: Text(
                                                '${g * _episodesPerGroup + 1}-${math.min(totalEpisodes, (g + 1) * _episodesPerGroup)}',
                                                style: const TextStyle(
                                                  fontSize: 13,
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
                          const SizedBox(height: 14),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: episodeIndices.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 5,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 2.9,
                                ),
                            itemBuilder: (context, idx) {
                              final epIndex = episodeIndices[idx];
                              final ep = activeLine!.episodes[epIndex];
                              final isWatchedEp = hist != null &&
                                  hist.line == activeLine.name &&
                                  hist.index == epIndex;
                              return TvFocusPill(
                                borderRadius: 12,
                                selected: isWatchedEp,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                onSelect: () => _openPlayer(
                                  lineIndex: _selectedLineIndex,
                                  episodeIndex: epIndex,
                                  initialPositionMs:
                                      isWatchedEp ? hist.resumePosition : 0,
                                ),
                                child: Center(
                                  child: Text(
                                    ep.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              );
                            },
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
      ),
    );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppleColors.labelPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

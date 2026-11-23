// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/episode_scraper.dart';
import '../core/models.dart';
import 'apple_theme.dart';
import 'poster_image.dart';

/// Shows an in-series Episode Scraping & Alignment sheet so users can:
/// - Automatically parse & re-sort episodes from noisy netdisk/CMS filenames
/// - Filter out trailers/PVs/extras (`预告/花絮/番外`)
/// - Calibrate episode offset (`-1` / `+1`) or override match title
/// - Re-scrape online per-episode metadata (titles, synopses, stills)
/// - Immediately align both episode selection and Danmaku episode matching.
Future<EpisodeScrapeOverride?> showEpisodeScrapeSheet({
  required BuildContext context,
  required String seriesTitle,
  required String year,
  required List<CmsEpisode> episodes,
  required EpisodeScrapeOverride currentOverride,
  bool isVariety = false,
  bool forceDark = false,
}) async {
  EpisodeScrapeOverride? result;
  await showAppleModalSheet<void>(
    context: context,
    title: '剧集刮削与集数校准',
    maxWidth: 520,
    builder: (ctx) => _EpisodeScrapeSheetBody(
      seriesTitle: seriesTitle,
      year: year,
      episodes: episodes,
      initialOverride: currentOverride,
      isVariety: isVariety,
      forceDark: forceDark,
      onApply: (next) {
        result = next;
        Navigator.of(ctx).pop();
      },
    ),
  );
  return result;
}

class _EpisodeScrapeSheetBody extends StatefulWidget {
  final String seriesTitle;
  final String year;
  final List<CmsEpisode> episodes;
  final EpisodeScrapeOverride initialOverride;
  final bool isVariety;
  final bool forceDark;
  final ValueChanged<EpisodeScrapeOverride> onApply;

  const _EpisodeScrapeSheetBody({
    required this.seriesTitle,
    required this.year,
    required this.episodes,
    required this.initialOverride,
    required this.isVariety,
    required this.forceDark,
    required this.onApply,
  });

  @override
  State<_EpisodeScrapeSheetBody> createState() => _EpisodeScrapeSheetBodyState();
}

class _EpisodeScrapeSheetBodyState extends State<_EpisodeScrapeSheetBody> {
  late final TextEditingController _titleController;
  late int _offset;
  late bool _sortByEp;
  late bool _hideSpecials;
  bool _scrapingOnline = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.initialOverride.customTitle.isNotEmpty
          ? widget.initialOverride.customTitle
          : EpisodeScraper.normalizeSeriesTitle(widget.seriesTitle),
    );
    _offset = widget.initialOverride.episodeOffset;
    _sortByEp = widget.initialOverride.sortByEpisodeNumber;
    _hideSpecials = widget.initialOverride.hideSpecials;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  EpisodeScrapeOverride _buildDraft({bool markEnabled = true}) {
    final normalizedDefault = EpisodeScraper.normalizeSeriesTitle(
      widget.seriesTitle,
    );
    final typed = _titleController.text.trim();
    final customTitle =
        (typed.isEmpty || typed == normalizedDefault) ? '' : typed;
    return EpisodeScrapeOverride(
      customTitle: customTitle,
      episodeOffset: _offset,
      sortByEpisodeNumber: _sortByEp,
      hideSpecials: _hideSpecials,
      enabled: markEnabled,
      manualEpisodeMap: widget.initialOverride.manualEpisodeMap,
    );
  }

  Future<void> _runOnlineScrape() async {
    if (_scrapingOnline) return;
    HapticFeedback.lightImpact();
    final targetTitle = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : EpisodeScraper.normalizeSeriesTitle(widget.seriesTitle);
    setState(() {
      _scrapingOnline = true;
      _sortByEp = true;
      _statusMessage = '正在重新刮削「$targetTitle」分集信息…';
    });
    try {
      final metaMap = await PosterLoader.fetchSeriesEpisodeMetadata(
        targetTitle,
        forceRefresh: true,
      );
      unawaited(
        PosterLoader.fetchSeriesEpisodeStills(
          targetTitle,
          year: widget.year,
        ),
      );
      if (!mounted) return;
      final preview = EpisodeScraper.scrapeLine(
        widget.episodes,
        override: _buildDraft(),
        seriesTitle: targetTitle,
      );
      setState(() {
        _scrapingOnline = false;
        _statusMessage = metaMap.isNotEmpty
            ? '刮削完成：识别 ${preview.recognizedCount} 集，已匹配 ${metaMap.length} 条分集元数据'
            : '本地集数识别完成：已识别 ${preview.recognizedCount} 集（共 ${widget.episodes.length} 项）';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scrapingOnline = false;
        _statusMessage = '在线元数据暂不可用，已使用本地智能集数识别';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.forceDark
        ? ApplePalette.dark
        : ApplePalette.of(context);
    final targetTitle = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : EpisodeScraper.normalizeSeriesTitle(widget.seriesTitle);
    final draft = _buildDraft();
    final scraped = EpisodeScraper.scrapeLine(
      widget.episodes,
      override: draft,
      seriesTitle: targetTitle,
    );
    final previewCount = math.min(scraped.visibleRawIndices.length, 6);
    final cardBg = palette.isDark
        ? const Color(0xFF23232A)
        : const Color(0xFFF2F3F7);
    final borderCol = palette.isDark
        ? const Color(0x28FFFFFF)
        : const Color(0x1A000000);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderCol, width: 0.7),
          ),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.sparkles,
                size: 16,
                color: palette.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusMessage ??
                      '共 ${widget.episodes.length} 项 · 识别 ${scraped.recognizedCount} 集'
                          '${scraped.specialCount > 0 ? ' · ${scraped.specialCount} 个预告/花絮' : ''}',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Match title input + online re-scrape trigger
        Text(
          '剧集刮削与弹幕匹配名称',
          style: TextStyle(
            color: palette.labelSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: CupertinoTextField(
                key: const Key('episode-scrape-title-field'),
                controller: _titleController,
                placeholder: '输入标准剧名（用于分集元数据与弹幕）',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 13.5,
                ),
                placeholderStyle: TextStyle(
                  color: palette.labelTertiary,
                  fontSize: 13,
                ),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: borderCol, width: 0.8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            CupertinoButton(
              key: const Key('episode-scrape-refresh-btn'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(36, 36),
              color: palette.accent,
              borderRadius: BorderRadius.circular(10),
              onPressed: _scrapingOnline ? null : _runOnlineScrape,
              child: _scrapingOnline
                  ? const CupertinoActivityIndicator(
                      radius: 8,
                      color: Colors.white,
                    )
                  : const Text(
                      '智能刮削',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Offset stepper + toggles
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderCol, width: 0.7),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '集数偏移校准（同步修正弹幕集数）',
                          style: TextStyle(
                            color: palette.labelPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _offset == 0
                              ? '当前无偏移'
                              : '所有正片集数 ${_offset > 0 ? '+$_offset' : '$_offset'}',
                          style: TextStyle(
                            color: palette.labelTertiary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _OffsetPillButton(
                    key: const Key('episode-scrape-offset-minus'),
                    icon: CupertinoIcons.minus,
                    palette: palette,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _offset = (_offset - 1).clamp(-500, 500));
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      _offset > 0 ? '+$_offset' : '$_offset',
                      key: const Key('episode-scrape-offset-value'),
                      style: TextStyle(
                        color: _offset == 0
                            ? palette.labelPrimary
                            : palette.accent,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _OffsetPillButton(
                    key: const Key('episode-scrape-offset-plus'),
                    icon: CupertinoIcons.plus,
                    palette: palette,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _offset = (_offset + 1).clamp(-500, 500));
                    },
                  ),
                ],
              ),
              Divider(height: 16, thickness: 0.5, color: borderCol),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '按识别集数自动重排',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoSwitch(
                    key: const Key('episode-scrape-sort-switch'),
                    value: _sortByEp,
                    activeTrackColor: palette.accent,
                    onChanged: (v) => setState(() => _sortByEp = v),
                  ),
                ],
              ),
              Divider(height: 14, thickness: 0.5, color: borderCol),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '隐藏预告 / 花絮 / 番外',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoSwitch(
                    key: const Key('episode-scrape-hide-specials-switch'),
                    value: _hideSpecials,
                    activeTrackColor: palette.accent,
                    onChanged: (v) => setState(() => _hideSpecials = v),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Live mapping preview
        if (previewCount > 0) ...[
          const SizedBox(height: 12),
          Text(
            '集数映射预览（前 $previewCount 项）',
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderCol, width: 0.7),
            ),
            child: Column(
              children: [
                for (var i = 0; i < previewCount; i++) ...[
                  if (i > 0)
                    Divider(height: 10, thickness: 0.4, color: borderCol),
                  Builder(
                    builder: (_) {
                      final rawIdx = scraped.visibleRawIndices[i];
                      final info = scraped.items[rawIdx];
                      final realMeta = info.isSpecial
                          ? null
                          : PosterLoader.peekEpisodeMeta(
                              targetTitle,
                              info.effectiveEpisodeNumber,
                            );
                      final mappedLabel = info.isSpecial
                          ? (info.specialTag ?? '特辑')
                          : '${info.compactLabel(isVariety: widget.isVariety)}'
                              '${realMeta != null && realMeta.title.trim().isNotEmpty ? ' · ${realMeta.title.trim()}' : ''}';
                      return Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: info.isSpecial
                                  ? const Color(0x33FF9F0A)
                                  : palette.accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              info.badgeLabel,
                              style: TextStyle(
                                color: info.isSpecial
                                    ? const Color(0xFFFF9F0A)
                                    : palette.accent,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              info.rawName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.labelSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            CupertinoIcons.arrow_right,
                            size: 11,
                            color: palette.labelTertiary,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 132),
                            child: Text(
                              mappedLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: palette.labelPrimary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),

        // Bottom actions
        Row(
          children: [
            Expanded(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 10),
                color: cardBg,
                borderRadius: BorderRadius.circular(999),
                onPressed: () {
                  widget.onApply(const EpisodeScrapeOverride());
                },
                child: Text(
                  '恢复默认',
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: CupertinoButton(
                key: const Key('episode-scrape-apply-btn'),
                padding: const EdgeInsets.symmetric(vertical: 10),
                color: palette.accent,
                borderRadius: BorderRadius.circular(999),
                onPressed: () {
                  widget.onApply(_buildDraft(markEnabled: true));
                },
                child: const Text(
                  '应用并校准弹幕',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OffsetPillButton extends StatelessWidget {
  final IconData icon;
  final ApplePalette palette;
  final VoidCallback onTap;

  const _OffsetPillButton({
    super.key,
    required this.icon,
    required this.palette,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: palette.isDark
              ? const Color(0xFF33333D)
              : const Color(0xFFE5E7EE),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 14, color: palette.labelPrimary),
      ),
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show Colors, InkWell, LinearProgressIndicator, Material;

import '../core/download_service.dart';
import 'apple_theme.dart';
import 'poster_image.dart';

/// All download tasks of one series (same confirmed source + privacy domain +
/// video), episodes ordered.
class DownloadSeriesGroup {
  final String key;
  final List<DownloadTask> tasks;
  final bool isPrivate;

  const DownloadSeriesGroup(
    this.key,
    this.tasks, {
    this.isPrivate = false,
  });

  DownloadTask get lead => tasks.first;
  String get title => lead.title;
  String get poster =>
      tasks.map((t) => t.poster).firstWhere((p) => p.trim().isNotEmpty, orElse: () => '');

  List<String> get lineNames {
    final seen = <String>[];
    for (final t in tasks) {
      final name = t.lineName.trim();
      if (name.isNotEmpty && !seen.contains(name)) seen.add(name);
    }
    return seen;
  }

  int get episodeCount => tasks.length;
  bool get isSingle => tasks.length == 1;
  int _count(DownloadStatus s) => tasks.where((t) => t.status == s).length;
  int get completedCount => _count(DownloadStatus.completed);
  int get downloadingCount => _count(DownloadStatus.downloading);
  int get queuedCount => _count(DownloadStatus.queued);
  int get pausedCount => _count(DownloadStatus.paused);
  int get failedCount => _count(DownloadStatus.failed);
  int get activeCount => tasks.where((t) => t.isActive).length;
  bool get allCompleted => completedCount == episodeCount;
  bool get hasActive => activeCount > 0;
  bool get canResume => pausedCount + failedCount > 0;

  /// Mean per-episode progress (completed episodes count as 100 %).
  double get progress {
    if (tasks.isEmpty) return 0;
    var sum = 0.0;
    for (final t in tasks) {
      sum += t.status == DownloadStatus.completed
          ? 1.0
          : t.progress.clamp(0.0, 1.0).toDouble();
    }
    return (sum / tasks.length).clamp(0.0, 1.0);
  }

  /// Combined live speed of the episodes currently downloading (bytes/s).
  double get speed => tasks
      .where((t) => t.status == DownloadStatus.downloading)
      .fold<double>(0, (s, t) => s + (t.speed > 0 ? t.speed : 0));

  int get completedBytes => tasks
      .where((t) => t.status == DownloadStatus.completed)
      .fold<int>(0, (s, t) => s + (t.totalBytes > 0 ? t.totalBytes : 0));
}

String _normalizeDownloadGroupApi(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme && parsed.hasAuthority) {
    final scheme = parsed.scheme.toLowerCase();
    final host = parsed.host.toLowerCase();
    final isDefaultPort = !parsed.hasPort ||
        (scheme == 'http' && parsed.port == 80) ||
        (scheme == 'https' && parsed.port == 443);
    final authority = parsed.userInfo.isNotEmpty
        ? '${parsed.userInfo}@$host${isDefaultPort ? '' : ':${parsed.port}'}'
        : '$host${isDefaultPort ? '' : ':${parsed.port}'}';
    // Normalize bare root `/` to empty path while preserving trailing slashes
    // on non-root paths so `/media` and `/media/` remain distinct endpoints.
    final path = parsed.path == '/' ? '' : parsed.path;
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    final fragment = parsed.hasFragment ? '#${parsed.fragment}' : '';
    return '$scheme://$authority$path$query$fragment';
  }
  return trimmed == '/' ? '' : trimmed;
}

String _groupKeyOf(DownloadTask t, {bool? isPrivateOverride}) {
  final stored = t.sourceSite;
  final isPriv = isPrivateOverride ?? (stored?.isEffectivelyPrivate ?? false);
  final subId = (stored?.subscriptionId ?? '').trim();
  final sourceKey =
      (stored != null && stored.sourceKey.isNotEmpty) ? stored.sourceKey : t.siteKey;
  final normApi = _normalizeDownloadGroupApi(
    (stored != null && stored.sourceApi.trim().isNotEmpty)
        ? stored.sourceApi
        : ((stored != null && stored.api.trim().isNotEmpty)
            ? stored.api
            : t.siteApi),
  );
  final siteType = stored?.type ?? t.siteType;
  final privacyDomain = isPriv ? 'priv' : 'pub';
  final originSig =
      '$privacyDomain\u0001$subId\u0001$siteType\u0001$normApi\u0001$sourceKey';
  final videoId = t.videoId.trim();
  if (videoId.isNotEmpty) return 'v\u0001$originSig\u0001$videoId';
  final title = t.title.trim();
  if (title.isNotEmpty) return 't\u0001$originSig\u0001$title';
  return 'u\u0001${t.id}';
}

/// Groups tasks by confirmed source identity (`privacyDomain` + `subscriptionId`
/// + `siteType` + case-preserving normalized `siteApi` + `siteKey`) and series
/// (`videoId`, falling back to `title`).
///
/// Group order follows the first appearance in [tasks] (the service lists the
/// newest first); episodes are ordered by line (first-added line first) and
/// then by episode index.
List<DownloadSeriesGroup> groupDownloadTasks(
  List<DownloadTask> tasks, {
  String Function(DownloadTask task)? groupKeyBuilder,
  bool Function(DownloadTask task)? isTaskPrivate,
}) {
  final order = <String>[];
  final buckets = <String, List<DownloadTask>>{};
  final bucketPrivate = <String, bool>{};
  for (final t in tasks) {
    final priv = isTaskPrivate != null
        ? isTaskPrivate(t)
        : (t.sourceSite?.isEffectivelyPrivate ?? false);
    final key = groupKeyBuilder != null
        ? groupKeyBuilder(t)
        : _groupKeyOf(t, isPrivateOverride: priv);
    final bucket = buckets[key];
    if (bucket == null) {
      order.add(key);
      buckets[key] = [t];
      bucketPrivate[key] = priv;
    } else {
      bucket.add(t);
      if (priv) bucketPrivate[key] = true;
    }
  }
  return [
    for (final key in order)
      DownloadSeriesGroup(
        key,
        _sortEpisodes(buckets[key]!),
        isPrivate: bucketPrivate[key] ?? false,
      ),
  ];
}

List<DownloadTask> _sortEpisodes(List<DownloadTask> list) {
  final lineRank = <String, int>{};
  for (final t in list) {
    final current = lineRank[t.lineName];
    if (current == null || t.createdAt < current) lineRank[t.lineName] = t.createdAt;
  }
  final sorted = List<DownloadTask>.of(list);
  sorted.sort((a, b) {
    final byLine = lineRank[a.lineName]!.compareTo(lineRank[b.lineName]!);
    if (byLine != 0) return byLine;
    final byName = a.lineName.compareTo(b.lineName);
    if (byName != 0) return byName;
    return a.episodeIndex.compareTo(b.episodeIndex);
  });
  return List<DownloadTask>.unmodifiable(sorted);
}

/// One-line aggregate status for a series header.
String downloadGroupStatusLabel(DownloadSeriesGroup g) {
  final total = g.episodeCount;
  final done = g.completedCount;
  if (g.allCompleted) {
    final bytes = g.completedBytes;
    return bytes > 0
        ? '已完成 $done/$total 集 · ${DownloadService.formatBytes(bytes)}'
        : '已完成 $done/$total 集';
  }
  final pct = '${(g.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
  final parts = <String>[];
  if (g.downloadingCount > 0) {
    parts.add('下载中');
  } else if (g.queuedCount > 0) {
    parts.add('等待中');
  } else if (g.pausedCount > 0) {
    parts.add('已暂停');
  }
  parts.add('已完成 $done/$total 集');
  parts.add(pct);
  final speed = g.speed;
  if (speed > 0) parts.add('${DownloadService.formatBytes(speed)}/s');
  if (g.failedCount > 0) parts.add('${g.failedCount} 集失败');
  return parts.join(' · ');
}

/// iOS 片库「离线下载」grouped view: one collapsible row per series, every
/// episode with its own progress once expanded. Single-episode series reuse
/// the host's plain row via [singleRowBuilder].
class IosDownloadGroupsView extends StatefulWidget {
  final List<DownloadTask> tasks;
  final Widget Function(DownloadTask task) singleRowBuilder;
  final ValueChanged<DownloadTask> onPlay;
  final ValueChanged<DownloadTask> onPause;
  final ValueChanged<DownloadTask> onResume;
  final ValueChanged<DownloadTask> onDeleteTask;
  final ValueChanged<DownloadSeriesGroup> onPauseGroup;
  final ValueChanged<DownloadSeriesGroup> onResumeGroup;
  final ValueChanged<DownloadSeriesGroup> onDeleteGroup;
  final Widget Function()? placeholderBuilder;
  final String Function(DownloadTask task)? groupKeyBuilder;
  final bool Function(DownloadTask task)? isTaskPrivate;

  const IosDownloadGroupsView({
    super.key,
    required this.tasks,
    required this.singleRowBuilder,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onDeleteTask,
    required this.onPauseGroup,
    required this.onResumeGroup,
    required this.onDeleteGroup,
    this.placeholderBuilder,
    this.groupKeyBuilder,
    this.isTaskPrivate,
  });

  /// Expanded series survive tab switches and the 4 Hz progress rebuilds.
  static final Set<String> _expandedMemory = <String>{};

  @visibleForTesting
  static void resetExpandedForTest() => _expandedMemory.clear();

  @override
  State<IosDownloadGroupsView> createState() => _IosDownloadGroupsViewState();
}

class _IosDownloadGroupsViewState extends State<IosDownloadGroupsView> {
  void _toggle(String key) {
    setState(() {
      final memory = IosDownloadGroupsView._expandedMemory;
      if (!memory.remove(key)) memory.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupDownloadTasks(
      widget.tasks,
      groupKeyBuilder: widget.groupKeyBuilder,
      isTaskPrivate: widget.isTaskPrivate,
    );
    return AppleGroupedSection(
      children: [
        for (final g in groups)
          if (g.isSingle)
            KeyedSubtree(
              key: ValueKey('ios-dl-single-${g.lead.id}'),
              child: widget.singleRowBuilder(g.lead),
            )
          else
            _SeriesBlock(
              key: ValueKey('ios-dl-group-${g.key}'),
              group: g,
              expanded: IosDownloadGroupsView._expandedMemory.contains(g.key),
              onToggle: () => _toggle(g.key),
              host: widget,
            ),
      ],
    );
  }
}

class _SeriesBlock extends StatelessWidget {
  final DownloadSeriesGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final IosDownloadGroupsView host;

  const _SeriesBlock({
    super.key,
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.host,
  });

  Widget _placeholder(BuildContext context) {
    final builder = host.placeholderBuilder;
    if (builder != null) return builder();
    return ColoredBox(
      color: ApplePalette.of(context).fill,
      child: Icon(
        CupertinoIcons.film,
        color: ApplePalette.of(context).labelTertiary,
        size: 18,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final g = group;
    final failedOnly = g.failedCount > 0 && !g.hasActive;
    final statusColor = g.allCompleted
        ? AppleColors.systemGreen
        : (failedOnly ? AppleColors.systemRed : palette.labelSecondary);
    final lines = g.lineNames;
    final subtitle = [
      if (lines.isNotEmpty) lines.join(' / '),
      '共 ${g.episodeCount} 集',
    ].join(' · ');
    final header = Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('ios-dl-group-header-${g.key}'),
        onTap: onToggle,
        highlightColor: Colors.white10,
        splashColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 56,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: PosterImage(
                          url: g.poster,
                          title: g.isPrivate ? '' : g.title,
                          isPrivate: g.isPrivate,
                          placeholder: _placeholder(context),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppleColors.systemBlue,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: palette.groupedSecondary, width: 1.5),
                        ),
                        child: Text(
                          '${g.episodeCount}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.labelSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    _ProgressLine(
                      key: ValueKey('ios-dl-group-progress-${g.key}'),
                      value: g.progress,
                      color: g.allCompleted
                          ? AppleColors.systemGreen
                          : (failedOnly
                              ? AppleColors.systemRed
                              : AppleColors.systemBlue),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      downloadGroupStatusLabel(g),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: statusColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (!g.allCompleted)
                CupertinoButton(
                  key: ValueKey('ios-dl-group-toggle-${g.key}'),
                  padding: const EdgeInsets.all(4),
                  minimumSize: const Size(34, 34),
                  onPressed: () => g.hasActive
                      ? host.onPauseGroup(g)
                      : host.onResumeGroup(g),
                  child: Icon(
                    g.hasActive
                        ? CupertinoIcons.pause_circle
                        : CupertinoIcons.arrow_clockwise_circle,
                    size: 26,
                    color: AppleColors.systemBlue,
                    semanticLabel: g.hasActive ? '暂停本剧全部' : '继续本剧全部',
                  ),
                ),
              CupertinoButton(
                key: ValueKey('ios-dl-group-delete-${g.key}'),
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(34, 34),
                onPressed: () => host.onDeleteGroup(g),
                child: Icon(
                  CupertinoIcons.trash,
                  size: 19,
                  color: palette.labelTertiary,
                  semanticLabel: '删除整部剧集',
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: palette.labelTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      container: true,
      expanded: expanded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      key: ValueKey('ios-dl-group-episodes-${g.key}'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final t in g.tasks)
                          _EpisodeRow(
                            key: ValueKey('ios-dl-ep-${t.id}'),
                            task: t,
                            showLine: lines.length > 1,
                            host: host,
                          ),
                        const SizedBox(height: 4),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  final DownloadTask task;
  final bool showLine;
  final IosDownloadGroupsView host;

  const _EpisodeRow({
    super.key,
    required this.task,
    required this.showLine,
    required this.host,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final t = task;
    final done = t.status == DownloadStatus.completed;
    final failed = t.status == DownloadStatus.failed;
    final statusColor = failed
        ? AppleColors.systemRed
        : (done ? AppleColors.systemGreen : palette.labelSecondary);
    IconData icon;
    VoidCallback action;
    String actionLabel;
    if (done) {
      icon = CupertinoIcons.play_circle_fill;
      action = () => host.onPlay(t);
      actionLabel = '播放';
    } else if (t.status == DownloadStatus.paused || failed) {
      icon = CupertinoIcons.arrow_clockwise_circle;
      action = () => host.onResume(t);
      actionLabel = '继续下载';
    } else {
      icon = CupertinoIcons.pause_circle;
      action = () => host.onPause(t);
      actionLabel = '暂停';
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: done ? () => host.onPlay(t) : null,
        highlightColor: Colors.white10,
        splashColor: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.only(left: 64),
          padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: palette.separator, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      showLine ? '${t.episodeName} · ${t.lineName}' : t.episodeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (!done) ...[
                      _ProgressLine(
                        key: ValueKey('ios-dl-ep-progress-${t.id}'),
                        value: t.progress,
                        color: failed ? AppleColors.systemRed : AppleColors.systemBlue,
                      ),
                      const SizedBox(height: 3),
                    ],
                    Text(
                      DownloadService.statusLabel(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: statusColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              CupertinoButton(
                key: ValueKey('ios-dl-ep-action-${t.id}'),
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(32, 32),
                onPressed: action,
                child: Icon(
                  icon,
                  size: 24,
                  color: done ? palette.labelPrimary : AppleColors.systemBlue,
                  semanticLabel: actionLabel,
                ),
              ),
              CupertinoButton(
                key: ValueKey('ios-dl-ep-delete-${t.id}'),
                padding: const EdgeInsets.all(4),
                minimumSize: const Size(32, 32),
                onPressed: () => host.onDeleteTask(t),
                child: Icon(
                  CupertinoIcons.trash,
                  size: 17,
                  color: palette.labelTertiary,
                  semanticLabel: '删除本集',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final double value;
  final Color color;
  const _ProgressLine({super.key, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: 3,
        backgroundColor: ApplePalette.of(context).fill,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}

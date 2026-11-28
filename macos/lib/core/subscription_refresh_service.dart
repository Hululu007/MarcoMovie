import 'dart:async';
import 'dart:io';

import 'cms_client.dart';
import 'cms_parser.dart';
import 'models.dart';
import 'storage_service.dart';

/// Result for a single subscription processed by [StagedSubscriptionRefreshService].
class SubscriptionRefreshItemResult {
  final String subscriptionId;
  final String name;
  final bool succeeded;
  final bool skipped;
  final bool previousKept;
  final int siteCount;
  final int liveCount;
  final int depotCount;
  final String errorMessage;
  final SubscriptionEntry? stagedEntry;

  const SubscriptionRefreshItemResult({
    required this.subscriptionId,
    required this.name,
    required this.succeeded,
    this.skipped = false,
    this.previousKept = true,
    this.siteCount = 0,
    this.liveCount = 0,
    this.depotCount = 0,
    this.errorMessage = '',
    this.stagedEntry,
  });
}

/// Aggregated result of a staged subscription refresh batch.
class SubscriptionRefreshSummary {
  final List<SubscriptionRefreshItemResult> results;
  final bool commitFailed;
  final String commitError;

  const SubscriptionRefreshSummary({
    required this.results,
    this.commitFailed = false,
    this.commitError = '',
  });

  int get updatedCount => results.where((r) => r.succeeded).length;
  int get skippedCount => results.where((r) => r.skipped).length;
  int get failedCount =>
      results.where((r) => !r.succeeded && !r.skipped).length;
  bool get hasUpdates => updatedCount > 0;
  bool get hasFailures => failedCount > 0 || commitFailed;

  String get summaryText {
    if (results.isEmpty) return '暂无可刷新的网络订阅';
    if (commitFailed) {
      return '订阅写入中断，已保留上次有效配置${commitError.isNotEmpty ? "（$commitError）" : ""}';
    }
    if (updatedCount > 0 && failedCount == 0) {
      return '已安全更新 $updatedCount 个订阅${skippedCount > 0 ? "（跳过 $skippedCount 个本地订阅）" : ""}';
    }
    if (updatedCount > 0 && failedCount > 0) {
      return '已更新 $updatedCount 个订阅，$failedCount 个失败已保留上次有效配置';
    }
    if (failedCount > 0) {
      final firstErr = results
          .firstWhere((r) => !r.succeeded && !r.skipped)
          .errorMessage;
      return '刷新失败，已保留上次有效配置${firstErr.isNotEmpty ? "：$firstErr" : ""}';
    }
    return '所选订阅均为本地导入，无需网络刷新';
  }
}

/// Two-phase staged subscription updater for macOS:
///
/// 1. **Stage & Validate**: Fetch remote payload into memory, reject network
///    errors, HTML error pages, malformed JSON/M3U, or empty configs with zero
///    usable sites/lives/depots—without mutating [StorageService].
/// 2. **Atomic Switch**: Commit validated candidates through
///    [StorageService.commitStagedSubscriptionUpdates], which performs atomic
///    `.tmp` write + flush + rename before switching live config. Any write
///    interruption leaves the previous valid config completely usable.
class StagedSubscriptionRefreshService {
  final StorageService storage;
  final CmsClient client;
  final Duration perSubscriptionTimeout;

  const StagedSubscriptionRefreshService({
    required this.storage,
    required this.client,
    this.perSubscriptionTimeout = const Duration(seconds: 20),
  });

  static bool isRefreshable(SubscriptionEntry entry) {
    final target = resolveRefreshUrl(entry);
    final uri = Uri.tryParse(target);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String resolveRefreshUrl(SubscriptionEntry entry) {
    final url = entry.url.trim();
    if (url.isNotEmpty) return url;
    return entry.warehouseUrl.trim();
  }

  /// Stages and validates a single remote [entry] without touching storage.
  Future<SubscriptionRefreshItemResult> stageOne(SubscriptionEntry entry) async {
    if (!isRefreshable(entry)) {
      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: false,
        skipped: true,
        previousKept: true,
      );
    }

    final targetUrl = resolveRefreshUrl(entry);
    try {
      final resolved = await client
          .resolveConfigInput(
            urlInput: targetUrl,
            defaultGroup: entry.group,
            isPrivate: entry.isEffectivelyPrivate,
            subscriptionId: entry.id,
            defaultName: entry.name,
          )
          .timeout(perSubscriptionTimeout);

      final raw = resolved.rawConfig.trim();
      if (raw.isEmpty) {
        return SubscriptionRefreshItemResult(
          subscriptionId: entry.id,
          name: entry.name,
          succeeded: false,
          previousKept: true,
          errorMessage: '远端返回空配置',
        );
      }

      if (_looksLikeHtmlErrorPage(raw)) {
        return SubscriptionRefreshItemResult(
          subscriptionId: entry.id,
          name: entry.name,
          succeeded: false,
          previousKept: true,
          errorMessage: '远端返回了网页错误页而非订阅配置',
        );
      }

      // Independent validation parse of the staged raw payload.
      final parsed = CmsParser.parseConfig(
        raw,
        origin: resolved.origin.isNotEmpty ? resolved.origin : targetUrl,
        defaultGroup: entry.group,
        isPrivate: entry.isEffectivelyPrivate,
        subscriptionId: entry.id,
        defaultName: entry.name,
      );

      final usableSites = parsed.supportedSites.length;
      final totalSites = parsed.sites.length;
      final totalLives = parsed.lives.length;
      final mergedDepots = <String, CmsDepot>{
        for (final d in entry.depots) d.url: d,
        for (final d in resolved.depots) d.url: d,
        for (final d in parsed.depots) d.url: d,
      }.values.toList(growable: false);

      if (totalSites == 0 && totalLives == 0 && mergedDepots.isEmpty) {
        return SubscriptionRefreshItemResult(
          subscriptionId: entry.id,
          name: entry.name,
          succeeded: false,
          previousKept: true,
          errorMessage: '新配置不包含任何片源、直播或子仓库',
        );
      }

      // Guard against degrading a previously working subscription into a
      // payload with zero playable/supported sites and zero lives/depots.
      final previouslyHadUsable =
          entry.siteCount > 0 || entry.liveCount > 0 || entry.depots.isNotEmpty;
      if (previouslyHadUsable &&
          usableSites == 0 &&
          totalLives == 0 &&
          mergedDepots.isEmpty) {
        return SubscriptionRefreshItemResult(
          subscriptionId: entry.id,
          name: entry.name,
          succeeded: false,
          previousKept: true,
          errorMessage: '新配置不含可用片源或直播源',
        );
      }

      final detectedFormat = mergedDepots.isNotEmpty
          ? '多仓'
          : CmsParser.detectSubscriptionFormat(
              raw,
              origin: resolved.origin.isNotEmpty ? resolved.origin : targetUrl,
            );

      final staged = entry.copyWith(
        url: resolved.origin.isNotEmpty ? resolved.origin : entry.url,
        warehouseUrl: entry.warehouseUrl.isNotEmpty
            ? entry.warehouseUrl
            : (mergedDepots.isNotEmpty ? targetUrl : ''),
        activeDepotName: resolved.activeDepotName.isNotEmpty
            ? resolved.activeDepotName
            : entry.activeDepotName,
        depots: mergedDepots,
        format: detectedFormat,
        rawContent: raw,
        siteCount: usableSites,
        liveCount: totalLives,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: true,
        previousKept: false,
        siteCount: usableSites,
        liveCount: totalLives,
        depotCount: mergedDepots.length,
        stagedEntry: staged,
      );
    } on TimeoutException {
      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: false,
        previousKept: true,
        errorMessage: '连接超时，网络无响应',
      );
    } on SocketException catch (e) {
      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: false,
        previousKept: true,
        errorMessage: '网络断开（${e.message.isNotEmpty ? e.message : "无法连接服务器"}）',
      );
    } on FormatException catch (e) {
      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: false,
        previousKept: true,
        errorMessage: '配置格式无效（${e.message}）',
      );
    } on Object catch (e) {
      return SubscriptionRefreshItemResult(
        subscriptionId: entry.id,
        name: entry.name,
        succeeded: false,
        previousKept: true,
        errorMessage: _formatBriefError(e),
      );
    }
  }

  /// Refreshes a single subscription using stage -> validate -> atomic switch.
  Future<SubscriptionRefreshSummary> refreshOne(SubscriptionEntry entry) =>
      refreshAll(targets: [entry]);

  /// Refreshes [targets] (defaults to all saved subscriptions) by staging and
  /// validating all remote entries first, then atomically committing all valid
  /// staged entries in one transaction.
  Future<SubscriptionRefreshSummary> refreshAll({
    List<SubscriptionEntry>? targets,
  }) async {
    final entries = targets ?? storage.getSubscriptions();
    if (entries.isEmpty) {
      return const SubscriptionRefreshSummary(results: []);
    }

    final stagedResults = <SubscriptionRefreshItemResult>[];
    final validToCommit = <SubscriptionEntry>[];

    for (final entry in entries) {
      final staged = await stageOne(entry);
      stagedResults.add(staged);
      if (staged.succeeded && staged.stagedEntry != null) {
        validToCommit.add(staged.stagedEntry!);
      }
    }

    if (validToCommit.isEmpty) {
      return SubscriptionRefreshSummary(results: stagedResults);
    }

    try {
      await storage.commitStagedSubscriptionUpdates(validToCommit);
      return SubscriptionRefreshSummary(results: stagedResults);
    } on Object catch (e) {
      final errText = _formatBriefError(e);
      final rolledBack = <SubscriptionRefreshItemResult>[
        for (final item in stagedResults)
          if (item.succeeded)
            SubscriptionRefreshItemResult(
              subscriptionId: item.subscriptionId,
              name: item.name,
              succeeded: false,
              previousKept: true,
              errorMessage: '写入中断，已保留上次有效配置（$errText）',
            )
          else
            item,
      ];
      return SubscriptionRefreshSummary(
        results: rolledBack,
        commitFailed: true,
        commitError: errText,
      );
    }
  }

  static bool _looksLikeHtmlErrorPage(String trimmed) {
    final head = trimmed.length > 512 ? trimmed.substring(0, 512) : trimmed;
    final lower = head.toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        (lower.startsWith('<head') && lower.contains('</html>')) ||
        (lower.contains('<title>404') || lower.contains('<title>502'));
  }

  static String _formatBriefError(Object error) {
    final raw = error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
    if (raw.length <= 120) return raw;
    return '${raw.substring(0, 117)}…';
  }
}

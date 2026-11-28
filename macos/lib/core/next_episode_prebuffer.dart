import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'bluray_iso_proxy.dart';
import 'cloud_media_proxy.dart';
import 'cms_client.dart';
import 'local_media_proxy.dart';
import 'models.dart';

/// User-configurable opt-in settings for next-episode prebuffering.
class NextEpisodePrebufferConfig {
  static const List<int> supportedTriggerSeconds = <int>[30, 45, 60, 90];
  static const List<int> supportedMaxMbOptions = <int>[4, 8, 16, 32];
  static const int defaultTriggerSeconds = 45;
  static const int defaultMaxMb = 8;

  final bool enabled;
  final int triggerRemainingSeconds;
  final int maxPrebufferMb;

  const NextEpisodePrebufferConfig({
    this.enabled = false,
    this.triggerRemainingSeconds = defaultTriggerSeconds,
    this.maxPrebufferMb = defaultMaxMb,
  });

  int get maxPrebufferBytes => maxPrebufferMb * 1024 * 1024;

  static int normalizeTriggerSeconds(int raw) {
    if (supportedTriggerSeconds.contains(raw)) return raw;
    return defaultTriggerSeconds;
  }

  static int normalizeMaxMb(int raw) {
    if (supportedMaxMbOptions.contains(raw)) return raw;
    return defaultMaxMb;
  }

  @override
  bool operator ==(Object other) =>
      other is NextEpisodePrebufferConfig &&
      other.enabled == enabled &&
      other.triggerRemainingSeconds == triggerRemainingSeconds &&
      other.maxPrebufferMb == maxPrebufferMb;

  @override
  int get hashCode =>
      Object.hash(enabled, triggerRemainingSeconds, maxPrebufferMb);
}

enum NextEpisodePrebufferCancelReason {
  exit,
  sourceSwitch,
  manualJump,
  liveMode,
  repeatOne,
  configDisabled,
  superseded,
}

/// Holds a resolved and head-prefetched next episode ready for immediate
/// adoption when playback transitions to the next episode.
class PreparedNextEpisode {
  final String siteKey;
  final String videoId;
  final int lineIndex;
  final int episodeIndex;
  final String rawEpisodeUrl;
  final CmsEpisode resolvedEpisode;
  final Completer<void> sourceAbort;
  final int prefetchedBytes;
  final int prefetchedBlocks;
  final int prepareDurationMs;
  final DateTime preparedAt;

  PreparedNextEpisode({
    required this.siteKey,
    required this.videoId,
    required this.lineIndex,
    required this.episodeIndex,
    required this.rawEpisodeUrl,
    required this.resolvedEpisode,
    required this.sourceAbort,
    required this.prefetchedBytes,
    required this.prefetchedBlocks,
    required this.prepareDurationMs,
    required this.preparedAt,
  });

  bool matches({
    required String siteKey,
    required String videoId,
    required int lineIndex,
    required int episodeIndex,
    required String rawEpisodeUrl,
  }) =>
      this.siteKey == siteKey &&
      this.videoId == videoId &&
      this.lineIndex == lineIndex &&
      this.episodeIndex == episodeIndex &&
      this.rawEpisodeUrl == rawEpisodeUrl;

  bool isExpired(DateTime now, {Duration ttl = const Duration(minutes: 5)}) =>
      now.difference(preparedAt) > ttl;

  Future<void> dispose() async {
    if (!sourceAbort.isCompleted) {
      sourceAbort.complete();
    }
    final cloudLease = _cloudLeaseOf(resolvedEpisode);
    if (cloudLease != null) {
      await cloudLease.close();
    }
  }
}

/// Manages opt-in, strictly bounded, cancellable next-episode prebuffering.
///
/// Design invariants:
/// - **Opt-in**: does nothing and sends 0 bytes when `config.enabled == false`.
/// - **Non-intrusive**: only triggers while current VOD episode is actively
///   playing smoothly (`playing && !loading && !buffering`) and remaining time
///   is within `config.triggerRemainingSeconds`.
/// - **Strict traffic cap**: media head prefetch is strictly bounded by
///   `config.maxPrebufferBytes` (or [debugMaxPrebufferBytesOverride] in tests).
/// - **Immediate cancellation**: exits, source/line switches, manual episode
///   jumps, live TV entry, or single-episode repeat immediately cancel both
///   in-flight URL resolution and HTTP prefetch requests and dispose any
///   unadopted resources.
class NextEpisodePrebufferController {
  NextEpisodePrebufferController({
    required CmsClient client,
    DiskBlockCache? diskCache,
    http.Client? prefetchHttpClient,
    DateTime Function()? clock,
    int? debugMaxPrebufferBytesOverride,
    CmsEpisode Function(CmsEpisode)? qualitySelector,
  })  : _client = client,
        _diskCache = diskCache ?? DiskBlockCache.shared,
        _injectedHttpClient = prefetchHttpClient,
        _clock = clock ?? DateTime.now,
        _debugMaxPrebufferBytesOverride = debugMaxPrebufferBytesOverride,
        _qualitySelector = qualitySelector;

  final CmsClient _client;
  final DiskBlockCache _diskCache;
  final http.Client? _injectedHttpClient;
  final DateTime Function() _clock;
  final int? _debugMaxPrebufferBytesOverride;
  final CmsEpisode Function(CmsEpisode)? _qualitySelector;

  int _generation = 0;
  Completer<void>? _activeAbort;
  Future<void>? _activeTask;
  String? _activeTargetKey;
  final Set<String> _attemptedKeys = <String>{};
  PreparedNextEpisode? _prepared;

  int _extraNetworkBytes = 0;
  int _hitCount = 0;
  int _cancelCount = 0;
  int _completedCount = 0;
  int _lastPrepareMs = 0;
  NextEpisodePrebufferCancelReason? _lastCancelReason;

  int get extraNetworkBytes => _extraNetworkBytes;
  int get hitCount => _hitCount;
  int get cancelCount => _cancelCount;
  int get completedCount => _completedCount;
  int get lastPrepareMs => _lastPrepareMs;
  bool get isRunning => _activeTask != null;
  bool get hasPrepared => _prepared != null;
  PreparedNextEpisode? get preparedSnapshot => _prepared;
  NextEpisodePrebufferCancelReason? get lastCancelReason => _lastCancelReason;

  static String _targetKey({
    required String siteKey,
    required String videoId,
    required int lineIndex,
    required int episodeIndex,
    required String rawEpisodeUrl,
  }) =>
      '$siteKey|$videoId|$lineIndex|$episodeIndex|$rawEpisodeUrl';

  bool shouldTrigger({
    required NextEpisodePrebufferConfig config,
    required bool isLive,
    required bool embedded,
    required bool isEmby,
    required bool isBlurayIso,
    required String repeatMode,
    required bool isPlaying,
    required bool isLoading,
    required bool isBuffering,
    required int positionMs,
    required int durationMs,
    required String siteKey,
    required String videoId,
    required int lineIndex,
    required int? nextEpisodeIndex,
    required CmsEpisode? nextEpisode,
  }) {
    if (!config.enabled) return false;
    if (isLive || embedded || isEmby || isBlurayIso) return false;
    if (repeatMode == 'one') return false;
    if (!isPlaying || isLoading || isBuffering) return false;
    if (durationMs <= 0 || positionMs <= 0) return false;
    if (nextEpisodeIndex == null || nextEpisode == null) return false;
    if (nextEpisode.isLocalFile || nextEpisode.url.trim().isEmpty) return false;

    final remainingMs = durationMs - positionMs;
    final triggerWindowMs = config.triggerRemainingSeconds * 1000;
    if (remainingMs > triggerWindowMs) return false;

    // Wait briefly into the current episode before starting background prefetch
    // so short test clips or instant seeks do not immediately contend with
    // current episode startup.
    final minSettledPositionMs = math.min(5000, durationMs ~/ 3);
    if (positionMs < minSettledPositionMs) return false;

    final key = _targetKey(
      siteKey: siteKey,
      videoId: videoId,
      lineIndex: lineIndex,
      episodeIndex: nextEpisodeIndex,
      rawEpisodeUrl: nextEpisode.url,
    );
    if (_activeTargetKey == key || _attemptedKeys.contains(key)) {
      return false;
    }
    if (_prepared != null &&
        _prepared!.matches(
          siteKey: siteKey,
          videoId: videoId,
          lineIndex: lineIndex,
          episodeIndex: nextEpisodeIndex,
          rawEpisodeUrl: nextEpisode.url,
        ) &&
        !_prepared!.isExpired(_clock())) {
      return false;
    }
    return true;
  }

  /// Evaluates eligibility and launches a background prebuffer task if ready.
  /// Returns the running task future if started, or `null` if skipped.
  Future<void>? maybeStart({
    required NextEpisodePrebufferConfig config,
    required CmsSite site,
    required String videoId,
    required int lineIndex,
    required int? nextEpisodeIndex,
    required CmsEpisode? nextEpisode,
    required bool isLive,
    required bool embedded,
    required bool isBlurayIso,
    required String repeatMode,
    required bool isPlaying,
    required bool isLoading,
    required bool isBuffering,
    required int positionMs,
    required int durationMs,
    List<CmsParse> parses = const [],
    List<CmsSniffRule> rules = const [],
    List<String> ads = const [],
    bool enableMediaHeadPrefetch = true,
  }) {
    if (!shouldTrigger(
      config: config,
      isLive: isLive,
      embedded: embedded,
      isEmby: site.isEmby,
      isBlurayIso: isBlurayIso,
      repeatMode: repeatMode,
      isPlaying: isPlaying,
      isLoading: isLoading,
      isBuffering: isBuffering,
      positionMs: positionMs,
      durationMs: durationMs,
      siteKey: site.key,
      videoId: videoId,
      lineIndex: lineIndex,
      nextEpisodeIndex: nextEpisodeIndex,
      nextEpisode: nextEpisode,
    )) {
      return null;
    }

    final targetIndex = nextEpisodeIndex!;
    final targetEpisode = nextEpisode!;
    final key = _targetKey(
      siteKey: site.key,
      videoId: videoId,
      lineIndex: lineIndex,
      episodeIndex: targetIndex,
      rawEpisodeUrl: targetEpisode.url,
    );

    // Replace any stale task or prepared episode for a different target.
    if (_activeTask != null || _prepared != null) {
      unawaited(cancelAll(NextEpisodePrebufferCancelReason.superseded));
    }

    final gen = ++_generation;
    final taskAbort = Completer<void>();
    _activeAbort = taskAbort;
    _activeTargetKey = key;
    _attemptedKeys.add(key);

    final maxBytes =
        _debugMaxPrebufferBytesOverride ?? config.maxPrebufferBytes;
    final task = _runPrebuffer(
      generation: gen,
      site: site,
      videoId: videoId,
      lineIndex: lineIndex,
      episodeIndex: targetIndex,
      rawEpisode: targetEpisode,
      taskAbort: taskAbort,
      maxBytes: maxBytes,
      parses: parses,
      rules: rules,
      ads: ads,
      enableMediaHeadPrefetch: enableMediaHeadPrefetch,
    );
    _activeTask = task;
    unawaited(task.whenComplete(() {
      if (_generation == gen) {
        _activeTask = null;
        _activeTargetKey = null;
      }
    }));
    return task;
  }

  Future<void> _runPrebuffer({
    required int generation,
    required CmsSite site,
    required String videoId,
    required int lineIndex,
    required int episodeIndex,
    required CmsEpisode rawEpisode,
    required Completer<void> taskAbort,
    required int maxBytes,
    required List<CmsParse> parses,
    required List<CmsSniffRule> rules,
    required List<String> ads,
    required bool enableMediaHeadPrefetch,
  }) async {
    final watch = Stopwatch()..start();
    http.Client? ownedClient;
    CmsEpisode? resolved;
    try {
      resolved = await _client
          .runSourceOperation(
            () => _client.resolveEpisodeForPlayback(
              site,
              rawEpisode,
              parses: parses,
              rules: rules,
              ads: ads,
            ),
            cancellation: taskAbort,
          )
          .timeout(const Duration(seconds: 25), onTimeout: () {
            if (!taskAbort.isCompleted) taskAbort.complete();
            throw TimeoutException('下一集预解析超时');
          });

      if (generation != _generation || taskAbort.isCompleted) {
        await _discardEpisodeLease(resolved);
        return;
      }

      if (_qualitySelector != null && resolved.variants.length > 1) {
        resolved = _qualitySelector(resolved);
      }

      var prefetchedBytes = 0;
      var prefetchedBlocks = 0;
      final cloudLease = _cloudLeaseOf(resolved);
      final targetUri = Uri.tryParse(resolved.url.trim());
      if (enableMediaHeadPrefetch &&
          cloudLease == null &&
          maxBytes > 0 &&
          targetUri != null &&
          (targetUri.scheme == 'http' || targetUri.scheme == 'https') &&
          !BlurayIsoProxy.isIsoTarget(resolved.url)) {
        final httpClient = _injectedHttpClient ??
            (ownedClient = _createPrefetchHttpClient());
        final headers = Map<String, String>.of(resolved.headers);
        if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
          headers['User-Agent'] =
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
        }
        final isHls =
            '${targetUri.path}?${targetUri.query}'.toLowerCase().contains('.m3u8');
        if (isHls) {
          final hlsResult = await _prefetchHlsHead(
            playlistUri: targetUri,
            headers: headers,
            maxBytes: maxBytes,
            client: httpClient,
            taskAbort: taskAbort,
          );
          prefetchedBytes = hlsResult.$1;
          prefetchedBlocks = hlsResult.$2;
        } else {
          final res = await _diskCache.prefetchHead(
            uri: targetUri,
            headers: headers,
            maxBytes: maxBytes,
            client: httpClient,
            isCancelled: () =>
                generation != _generation || taskAbort.isCompleted,
            cancelFuture: taskAbort.future,
          );
          prefetchedBytes = res.bytesFetched;
          prefetchedBlocks = res.blocksCached;
        }
        _extraNetworkBytes += prefetchedBytes;
      }

      if (generation != _generation || taskAbort.isCompleted) {
        await _discardEpisodeLease(resolved);
        return;
      }

      watch.stop();
      _lastPrepareMs = watch.elapsedMilliseconds;
      _completedCount++;
      _prepared = PreparedNextEpisode(
        siteKey: site.key,
        videoId: videoId,
        lineIndex: lineIndex,
        episodeIndex: episodeIndex,
        rawEpisodeUrl: rawEpisode.url,
        resolvedEpisode: resolved,
        sourceAbort: taskAbort,
        prefetchedBytes: prefetchedBytes,
        prefetchedBlocks: prefetchedBlocks,
        prepareDurationMs: watch.elapsedMilliseconds,
        preparedAt: _clock(),
      );
    } on Object {
      await _discardEpisodeLease(resolved);
      if (!taskAbort.isCompleted) {
        taskAbort.complete();
      }
    } finally {
      ownedClient?.close();
    }
  }

  Future<(int, int)> _prefetchHlsHead({
    required Uri playlistUri,
    required Map<String, String> headers,
    required int maxBytes,
    required http.Client client,
    required Completer<void> taskAbort,
  }) async {
    var totalFetched = 0;
    var totalBlocks = 0;
    final playlistCap = math.min(maxBytes, 512 * 1024);
    final req = http.AbortableRequest(
      'GET',
      playlistUri,
      abortTrigger: taskAbort.future,
    )..followRedirects = true;
    req.headers.addAll(headers);
    final resp = await client.send(req);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.stream.listen((_) {}).cancel();
      return (0, 0);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in resp.stream) {
      if (taskAbort.isCompleted) return (totalFetched, totalBlocks);
      final remaining = playlistCap - bytes.length;
      if (remaining <= 0) break;
      bytes.add(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
    }
    final rawBytes = bytes.takeBytes();
    totalFetched += rawBytes.length;
    final text = utf8.decode(rawBytes, allowMalformed: true);
    final segments = <Uri>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final resolvedSeg = playlistUri.resolve(trimmed);
      if (resolvedSeg.scheme == 'http' || resolvedSeg.scheme == 'https') {
        segments.add(resolvedSeg);
        if (segments.length >= 2) break;
      }
    }
    for (final segUri in segments) {
      if (taskAbort.isCompleted) break;
      final remaining = maxBytes - totalFetched;
      if (remaining <= 0) break;
      final res = await _diskCache.prefetchHead(
        uri: segUri,
        headers: headers,
        maxBytes: remaining,
        client: client,
        isCancelled: () => taskAbort.isCompleted,
        cancelFuture: taskAbort.future,
      );
      totalFetched += res.bytesFetched;
      totalBlocks += res.blocksCached;
    }
    return (totalFetched, totalBlocks);
  }

  /// Adopts a matching prepared next episode (transferring ownership of its
  /// [PreparedNextEpisode.sourceAbort] and any cloud lease to the caller).
  ///
  /// If a prepared episode exists for a *different* episode, it is cancelled
  /// and disposed immediately.
  PreparedNextEpisode? adoptPrepared({
    required String siteKey,
    required String videoId,
    required int lineIndex,
    required int episodeIndex,
    required String rawEpisodeUrl,
  }) {
    final prepared = _prepared;
    if (prepared != null &&
        prepared.matches(
          siteKey: siteKey,
          videoId: videoId,
          lineIndex: lineIndex,
          episodeIndex: episodeIndex,
          rawEpisodeUrl: rawEpisodeUrl,
        ) &&
        !prepared.isExpired(_clock())) {
      _prepared = null;
      _activeAbort = null;
      _activeTask = null;
      _activeTargetKey = null;
      _hitCount++;
      return prepared;
    }
    return null;
  }

  /// Immediately cancels any in-flight prebuffer task and disposes any
  /// unadopted prepared episode.
  Future<void> cancelAll(NextEpisodePrebufferCancelReason reason) async {
    final hadWork = _activeTask != null ||
        _activeAbort != null ||
        _prepared != null;
    _generation++;
    _lastCancelReason = reason;
    if (hadWork) {
      _cancelCount++;
    }
    final abort = _activeAbort;
    _activeAbort = null;
    _activeTask = null;
    _activeTargetKey = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    final stale = _prepared;
    _prepared = null;
    if (reason != NextEpisodePrebufferCancelReason.superseded) {
      _attemptedKeys.clear();
    }
    if (stale != null) {
      await stale.dispose();
    }
  }

  static Future<void> _discardEpisodeLease(CmsEpisode? episode) async {
    if (episode == null) return;
    final lease = _cloudLeaseOf(episode);
    if (lease != null) {
      await lease.close();
    }
  }

  static http.Client _createPrefetchHttpClient() {
    final io = HttpClient()
      ..autoUncompress = true
      ..maxConnectionsPerHost = 4
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 20);
    return IOClient(io);
  }
}

CloudMediaLease? _cloudLeaseOf(CmsEpisode episode) {
  final value = episode.playbackSession['cloudMediaLease'];
  return value is CloudMediaLease ? value : null;
}


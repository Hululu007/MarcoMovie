import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ohos_runtime.dart';
import 'block_filter.dart';
import 'provider.dart';

class _RefreshFlight {
  final int fromEpoch;
  final Completer<DanmuEpisodeSession?> completer =
      Completer<DanmuEpisodeSession?>();

  _RefreshFlight(this.fromEpoch);
}

/// Windowed 30-second danmu cache with signed effective-clock snapshots, 3-window LRU pinning
/// (`{w-1, w, w+1}`), 60% prefetch, HTTP 410 singleflight epoch refresh, and 180ms seek debounce.
///
/// Automatically disabled when [OhosRuntime.isOhos] is true.
class DanmuSegmentCache extends ChangeNotifier {
  static const int windowDurationMs = 30000;
  static const int maxCommentLifetimeMs = 12000;
  static const int prefetchOffsetMs = 18000;
  static const int maxCachedWindows = 24;
  static const int maxWindowItems = 1500;
  static const int maxTotalItems = 18000;
  static const int maxSession410Refreshes = 3;
  static const int seekDebounceMs = 180;

  final DanmuProvider provider;
  final int _seekDebounceMs;

  // Access-order LRU via LinkedHashMap (remove + re-insert on touch)
  final LinkedHashMap<int, List<DanmuItem>> _windowCache =
      LinkedHashMap<int, List<DanmuItem>>();
  final Map<int, DanmuCancelToken> _inFlightWindows = <int, DanmuCancelToken>{};
  final Set<int> _retried410Windows = <int>{};

  String _boundEpisodeId = '';
  DanmuEpisodeSession? _activeSession;
  DanmuCancelToken? _openToken;
  int _bindGeneration = 0;
  int _sessionEpoch = 0;
  int _session410RefreshCount = 0;
  _RefreshFlight? _activeRefreshFlight;
  int? _activePrefetchWindow;
  int? _pendingWindowAfterOpen;

  int _timeOffsetMs = 0;
  int _currentPinnedWindow = 0;
  int _totalCachedItems = 0;
  bool _seeking = false;
  Timer? _seekTimer;
  DanmuBlockFilter _blockFilter = DanmuBlockFilter.empty;
  bool _disposed = false;
  int _activeTaskCount = 0;
  Completer<void>? _idleCompleter;

  DanmuSegmentCache({
    required this.provider,
    int seekDebounceMs = DanmuSegmentCache.seekDebounceMs,
  }) : _seekDebounceMs = math.max(0, seekDebounceMs);

  static int computeEffectiveMs(int rawPositionMs, int timeOffsetMs) =>
      rawPositionMs + timeOffsetMs;

  static int computeFetchWindowIndex(int effectiveMs) =>
      effectiveMs < 0 ? 0 : effectiveMs ~/ windowDurationMs;

  int get timeOffsetMs => _timeOffsetMs;
  int get sessionEpoch => _sessionEpoch;
  int get session410RefreshCount => _session410RefreshCount;
  int get cachedWindowCount => _windowCache.length;
  int get totalCachedItemCount => _totalCachedItems;
  DanmuEpisodeSession? get currentSession => _activeSession;
  bool isWindowCached(int windowIndex) => _windowCache.containsKey(windowIndex);

  void setBlockFilter(DanmuBlockFilter filter) {
    _blockFilter = filter;
    if (!_disposed) notifyListeners();
  }

  void setTimeOffsetMs(int offsetMs) {
    _timeOffsetMs = offsetMs.clamp(-30000, 30000);
    if (!_disposed) notifyListeners();
  }

  Future<void> bindSession(String boundEpisodeId) async {
    if (_disposed || OhosRuntime.isOhos) return;
    _cancelInFlight(cancelOpen: true);
    _bindGeneration++;
    final gen = _bindGeneration;

    _boundEpisodeId = boundEpisodeId.trim();
    _activeSession = null;
    _sessionEpoch = 0;
    _session410RefreshCount = 0;
    _activeRefreshFlight = null;
    _retried410Windows.clear();
    _windowCache.clear();
    _totalCachedItems = 0;
    _currentPinnedWindow = 0;
    _pendingWindowAfterOpen = null;
    _seeking = false;

    if (_boundEpisodeId.isEmpty) return;

    final token = DanmuCancelToken();
    _openToken = token;
    _beginTask();
    try {
      final session = await provider.openSession(
        _boundEpisodeId,
        cancelToken: token,
      );
      if (_disposed || gen != _bindGeneration || token.isCancelled) return;
      _activeSession = session;
      _openToken = null;
      final pendingW = _pendingWindowAfterOpen;
      _pendingWindowAfterOpen = null;
      if (!_seeking && pendingW != null && pendingW >= 0) {
        _startWindowFetch(pendingW, isPrefetch: false, gen: gen);
      }
      if (!_disposed) notifyListeners();
    } catch (_) {
      if (gen == _bindGeneration) {
        _openToken = null;
      }
    } finally {
      _endTask();
    }
  }

  void onPlaybackTick(int rawPositionMs, {required bool playing}) {
    if (_disposed || OhosRuntime.isOhos || _boundEpisodeId.isEmpty) return;
    final effectiveMs = computeEffectiveMs(rawPositionMs, _timeOffsetMs);
    final w = computeFetchWindowIndex(effectiveMs);
    _currentPinnedWindow = w;
    _evictIfNeeded();
    if (_seeking) return;

    if (_activeSession == null) {
      _pendingWindowAfterOpen = w;
      return;
    }

    if (!_windowCache.containsKey(w) && !_inFlightWindows.containsKey(w)) {
      _startWindowFetch(w, isPrefetch: false, gen: _bindGeneration);
    }

    final windowStartMs = w * windowDurationMs;
    if (playing && effectiveMs >= windowStartMs + prefetchOffsetMs) {
      final nextW = w + 1;
      if (_activePrefetchWindow == null &&
          !_windowCache.containsKey(nextW) &&
          !_inFlightWindows.containsKey(nextW)) {
        _startWindowFetch(nextW, isPrefetch: true, gen: _bindGeneration);
      }
    }
  }

  void onSeekChanged(int targetRawPositionMs) {
    if (_disposed || OhosRuntime.isOhos) return;
    _seeking = true;
    _cancelInFlight(cancelOpen: false);
    final gen = _bindGeneration;

    void settle() {
      if (_disposed || gen != _bindGeneration) return;
      _seeking = false;
      _seekTimer = null;
      final effectiveMs = computeEffectiveMs(targetRawPositionMs, _timeOffsetMs);
      final targetW = computeFetchWindowIndex(effectiveMs);
      _currentPinnedWindow = targetW;
      _evictIfNeeded();
      if (_activeSession == null) {
        _pendingWindowAfterOpen = targetW;
        return;
      }
      if (!_windowCache.containsKey(targetW) &&
          !_inFlightWindows.containsKey(targetW)) {
        _startWindowFetch(targetW, isPrefetch: false, gen: gen);
      }
      _checkIdle();
    }

    if (_seekDebounceMs == 0) {
      settle();
    } else {
      _seekTimer = Timer(Duration(milliseconds: _seekDebounceMs), settle);
    }
  }

  List<DanmuItem> snapshotForPosition(int rawPositionMs) {
    if (_disposed || OhosRuntime.isOhos) return const <DanmuItem>[];
    final effectiveMs = computeEffectiveMs(rawPositionMs, _timeOffsetMs);
    // Signed effective clock: negative effectiveMs returns empty list so 0.0s danmu never freeze!
    if (effectiveMs < 0) return const <DanmuItem>[];

    final w = effectiveMs ~/ windowDurationMs;
    final prevItems = w > 0 ? _touchWindow(w - 1) : null;
    final currItems = _touchWindow(w);
    if ((prevItems == null || prevItems.isEmpty) &&
        (currItems == null || currItems.isEmpty)) {
      return const <DanmuItem>[];
    }

    final minTimeMs = effectiveMs - maxCommentLifetimeMs;
    final merged = <String, DanmuItem>{};
    _collectVisible(prevItems, minTimeMs, effectiveMs, merged);
    _collectVisible(currItems, minTimeMs, effectiveMs, merged);
    if (merged.isEmpty) return const <DanmuItem>[];

    final out = merged.values.toList(growable: false);
    out.sort(DanmuItem.compareOrder);
    return out;
  }

  void _collectVisible(
    List<DanmuItem>? source,
    int minTimeMs,
    int maxTimeMs,
    Map<String, DanmuItem> dest,
  ) {
    if (source == null || source.isEmpty) return;
    var lo = 0;
    var hi = source.length;
    while (lo < hi) {
      final mid = (lo + hi) >>> 1;
      if (source[mid].timeMs < minTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final hasFilter = !_blockFilter.isEmpty;
    for (var i = lo; i < source.length; i++) {
      final item = source[i];
      if (item.timeMs > maxTimeMs) break;
      if (item.timeMs < minTimeMs) continue;
      if (hasFilter && _blockFilter.isBlocked(item.text)) continue;
      dest.putIfAbsent(item.id, () => item);
    }
  }

  List<DanmuItem>? _touchWindow(int windowIndex) {
    final existing = _windowCache.remove(windowIndex);
    if (existing != null) {
      _windowCache[windowIndex] = existing;
    }
    return existing;
  }

  void _startWindowFetch(
    int windowIndex, {
    required bool isPrefetch,
    required int gen,
  }) {
    final sessionSnapshot = _activeSession;
    if (sessionSnapshot == null || windowIndex < 0) return;
    if (_windowCache.containsKey(windowIndex) ||
        _inFlightWindows.containsKey(windowIndex)) {
      return;
    }
    final epochSnapshot = _sessionEpoch;
    final token = DanmuCancelToken();
    _inFlightWindows[windowIndex] = token;
    if (isPrefetch) {
      _activePrefetchWindow = windowIndex;
    }
    _beginTask();

    () async {
      try {
        final items = await _fetchWith410Handling(
          sessionSnapshot,
          epochSnapshot,
          windowIndex,
          gen,
          token,
        );
        if (items != null &&
            !_disposed &&
            gen == _bindGeneration &&
            !token.isCancelled) {
          _putWindow(windowIndex, items);
          notifyListeners();
        }
      } catch (_) {
        // Isolated error; leave uncached or empty on permanent 410.
      } finally {
        if (_inFlightWindows[windowIndex] == token) {
          _inFlightWindows.remove(windowIndex);
        }
        if (isPrefetch && _activePrefetchWindow == windowIndex) {
          _activePrefetchWindow = null;
        }
        _endTask();
      }
    }();
  }

  Future<List<DanmuItem>?> _fetchWith410Handling(
    DanmuEpisodeSession sessionSnapshot,
    int usedEpoch,
    int windowIndex,
    int gen,
    DanmuCancelToken token,
  ) async {
    try {
      return await provider.fetchWindow(
        sessionSnapshot,
        windowIndex,
        cancelToken: token,
      );
    } on DanmuHttpException catch (ex) {
      if (ex.statusCode != 410) rethrow;
      final retrySession = await _resolveSingleflight410Refresh(
        usedEpoch,
        windowIndex,
        gen,
        token,
      );
      if (retrySession == null) return const <DanmuItem>[];
      try {
        return await provider.fetchWindow(
          retrySession,
          windowIndex,
          cancelToken: token,
        );
      } on DanmuHttpException catch (retryErr) {
        if (retryErr.statusCode == 410) {
          return const <DanmuItem>[];
        }
        rethrow;
      }
    }
  }

  Future<DanmuEpisodeSession?> _resolveSingleflight410Refresh(
    int usedEpoch,
    int windowIndex,
    int gen,
    DanmuCancelToken token,
  ) async {
    if (_disposed || gen != _bindGeneration || token.isCancelled) return null;
    if (_retried410Windows.contains(windowIndex)) {
      return null;
    }
    _retried410Windows.add(windowIndex);

    // Already refreshed to newer epoch by another concurrent caller
    if (_sessionEpoch > usedEpoch && _activeSession != null) {
      return _activeSession;
    }

    // Join in-flight singleflight refresh for the same epoch
    final existingFlight = _activeRefreshFlight;
    if (existingFlight != null && existingFlight.fromEpoch == usedEpoch) {
      return existingFlight.completer.future;
    }

    if (_session410RefreshCount >= maxSession410Refreshes) {
      return null;
    }
    _session410RefreshCount++;
    final flight = _RefreshFlight(usedEpoch);
    _activeRefreshFlight = flight;

    try {
      final refreshed = await provider.openSession(
        _boundEpisodeId,
        cancelToken: token,
      );
      if (!_disposed && gen == _bindGeneration) {
        _activeSession = refreshed;
        _sessionEpoch++;
        if (_activeRefreshFlight == flight) _activeRefreshFlight = null;
        if (!flight.completer.isCompleted) {
          flight.completer.complete(refreshed);
        }
        return refreshed;
      }
      if (_activeRefreshFlight == flight) _activeRefreshFlight = null;
      if (!flight.completer.isCompleted) flight.completer.complete(null);
      return null;
    } catch (_) {
      if (_activeRefreshFlight == flight) _activeRefreshFlight = null;
      if (!flight.completer.isCompleted) flight.completer.complete(null);
      return null;
    }
  }

  void _putWindow(int windowIndex, List<DanmuItem> items) {
    final bounded = items.length > maxWindowItems
        ? List<DanmuItem>.unmodifiable(items.subListSafe(0, maxWindowItems))
        : List<DanmuItem>.unmodifiable(items);
    final prev = _windowCache.remove(windowIndex);
    if (prev != null) {
      _totalCachedItems -= prev.length;
    }
    _windowCache[windowIndex] = bounded;
    _totalCachedItems += bounded.length;
    _evictIfNeeded();
  }

  bool _isPinned(int windowIndex) {
    final prev = math.max(0, _currentPinnedWindow - 1);
    return windowIndex == prev ||
        windowIndex == _currentPinnedWindow ||
        windowIndex == _currentPinnedWindow + 1;
  }

  void _evictIfNeeded() {
    while (_windowCache.length > maxCachedWindows ||
        _totalCachedItems > maxTotalItems) {
      int? victim;
      for (final key in _windowCache.keys) {
        if (!_isPinned(key)) {
          victim = key;
          break;
        }
      }
      if (victim == null) break;
      final removed = _windowCache.remove(victim);
      if (removed != null) {
        _totalCachedItems -= removed.length;
      }
    }
  }

  void _cancelInFlight({required bool cancelOpen}) {
    _seekTimer?.cancel();
    _seekTimer = null;
    for (final token in _inFlightWindows.values) {
      token.cancel();
    }
    _inFlightWindows.clear();
    _activePrefetchWindow = null;
    if (cancelOpen) {
      _openToken?.cancel();
      _openToken = null;
    }
  }

  void _beginTask() {
    _activeTaskCount++;
  }

  void _endTask() {
    _activeTaskCount = math.max(0, _activeTaskCount - 1);
    _checkIdle();
  }

  void _checkIdle() {
    if (_activeTaskCount == 0 && _seekTimer == null) {
      final c = _idleCompleter;
      _idleCompleter = null;
      if (c != null && !c.isCompleted) {
        c.complete();
      }
    }
  }

  Future<void> waitUntilIdle({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_activeTaskCount == 0 && _seekTimer == null) return;
    _idleCompleter ??= Completer<void>();
    await _idleCompleter!.future.timeout(timeout);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelInFlight(cancelOpen: true);
    _windowCache.clear();
    _totalCachedItems = 0;
    final c = _idleCompleter;
    _idleCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
    super.dispose();
  }
}

extension _SafeSublist on List<DanmuItem> {
  List<DanmuItem> subListSafe(int start, int end) =>
      sublist(start, math.min(end, length));
}

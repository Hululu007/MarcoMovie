import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'cms_client.dart';
import 'cms_parser.dart';
import 'models.dart';
import 'source_playback.dart';

/// Lifecycle of one offline download.
enum DownloadStatus { queued, downloading, paused, completed, failed }

/// One downloadable episode, persisted across launches.
class DownloadTask {
  final String id;
  final String siteKey;
  final String siteName;
  final String siteApi;
  final int siteType;
  final String videoId;
  final String title;
  final String poster;
  final String lineName;
  final String episodeName;
  final int episodeIndex;
  final String sourceUrl;
  final Map<String, String> headers;
  final CmsSite? sourceSite;
  final List<CmsParse> sourceParses;
  final int createdAt;
  Uri? _credentialOrigin;
  final Map<String, String> _redirectedUrls = {};
  DownloadStatus status;
  double progress;
  int receivedBytes;
  int totalBytes;
  String filePath;
  String error;
  double speed = 0;

  /// Bytes actually pulled off the network during this app session (also
  /// counts in-flight HLS segment chunks), used only for the speed meter so the
  /// displayed rate no longer drops to 0 between whole-segment completions.
  int _wireBytes = 0;

  DownloadTask({
    required this.id,
    required this.siteKey,
    required this.siteName,
    required this.siteApi,
    required this.siteType,
    required this.videoId,
    required this.title,
    required this.poster,
    required this.lineName,
    required this.episodeName,
    required this.episodeIndex,
    required this.sourceUrl,
    required this.headers,
    required this.createdAt,
    this.sourceSite,
    this.sourceParses = const [],
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.filePath = '',
    this.error = '',
  });

  bool get isActive =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteKey': siteKey,
        'siteName': siteName,
        'siteApi': siteApi,
        'siteType': siteType,
        'videoId': videoId,
        'title': title,
        'poster': poster,
        'lineName': lineName,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'sourceUrl': sourceUrl,
        'headers': headers,
        if (sourceSite != null) 'sourceSite': {
          'key': sourceSite!.key, 'originalKey': sourceSite!.originalKey,
          'name': sourceSite!.name, 'type': sourceSite!.type, 'api': sourceSite!.api,
          'playUrl': sourceSite!.playUrl, 'ext': sourceSite!.ext,
          'rawExtension': sourceSite!.rawExtension, 'jar': sourceSite!.jar,
          'spider': sourceSite!.spider, 'headers': sourceSite!.headers,
          'searchable': sourceSite!.searchable, 'group': sourceSite!.group,
          'isPrivate': sourceSite!.isPrivate, 'subscriptionId': sourceSite!.subscriptionId,
        },
        if (sourceParses.isNotEmpty) 'sourceParses': [
          for (final p in sourceParses) {
            'name': p.name, 'url': p.url, 'type': p.type,
            if (p.headers.isNotEmpty) 'headers': p.headers,
          },
        ],
        'createdAt': createdAt,
        'status': status.name,
        'progress': progress,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'filePath': filePath,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final statusName = (j['status'] ?? '').toString();
    var status = DownloadStatus.paused;
    for (final s in DownloadStatus.values) {
      if (s.name == statusName) status = s;
    }
    final rawHeaders = j['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    final source = j['sourceSite'];
    final sourceSite = source is Map ? CmsSite(
      key: '${source['key'] ?? ''}', originalKey: source['originalKey'] as String?,
      name: '${source['name'] ?? ''}', type: asInt(source['type']),
      api: '${source['api'] ?? ''}', playUrl: '${source['playUrl'] ?? ''}',
      ext: '${source['ext'] ?? ''}', rawExtension: source['rawExtension'] as String?,
      jar: '${source['jar'] ?? ''}', spider: '${source['spider'] ?? ''}',
      headers: source['headers'] is Map
          ? (source['headers'] as Map).map((k, v) => MapEntry('$k', '$v')) : const {},
      searchable: source['searchable'] != false, group: '${source['group'] ?? '默认分组'}',
      isPrivate: source['isPrivate'] == true, subscriptionId: '${source['subscriptionId'] ?? ''}',
    ) : null;
    final rawParses = j['sourceParses'];
    final sourceParses = <CmsParse>[];
    if (rawParses is List) {
      for (final item in rawParses) {
        if (item is! Map) continue;
        final url = '${item['url'] ?? ''}'.trim();
        if (url.isEmpty) continue;
        sourceParses.add(CmsParse(
          name: '${item['name'] ?? '解析'}'.trim(),
          url: url,
          type: asInt(item['type']),
          headers: item['headers'] is Map
              ? (item['headers'] as Map).map((k, v) => MapEntry('$k', '$v'))
              : const {},
        ));
      }
    }
    return DownloadTask(
      id: (j['id'] ?? '').toString(),
      siteKey: (j['siteKey'] ?? '').toString(),
      siteName: (j['siteName'] ?? '').toString(),
      siteApi: (j['siteApi'] ?? '').toString(),
      siteType: asInt(j['siteType']),
      videoId: (j['videoId'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      poster: (j['poster'] ?? '').toString(),
      lineName: (j['lineName'] ?? '').toString(),
      episodeName: (j['episodeName'] ?? '').toString(),
      episodeIndex: asInt(j['episodeIndex']),
      sourceUrl: (j['sourceUrl'] ?? '').toString(),
      headers: headers,
      sourceSite: sourceSite,
      sourceParses: sourceParses,
      createdAt: asInt(j['createdAt']),
      status: status,
      progress: (j['progress'] is num) ? (j['progress'] as num).toDouble() : 0,
      receivedBytes: asInt(j['receivedBytes']),
      totalBytes: asInt(j['totalBytes']),
      filePath: (j['filePath'] ?? '').toString(),
      error: (j['error'] ?? '').toString(),
    );
  }
}

class _StopSignal implements Exception {
  const _StopSignal();
}

class _DownloadError implements Exception {
  final String message;
  final bool retryable;
  const _DownloadError(this.message, {this.retryable = false});
  @override
  String toString() => message;
}

/// Raised when a server that advertised `Accept-Ranges: bytes` does not honour
/// a ranged request; the caller falls back to one sequential connection.
class _ParallelRangeUnsupported implements Exception {
  const _ParallelRangeUnsupported();
}

class _FetchedBytes {
  final Uint8List bytes;
  final String contentType;
  const _FetchedBytes(this.bytes, this.contentType);
}

class _Meter {
  int bytes;
  DateTime time;
  _Meter(this.bytes, this.time);
}

class _HlsByteRange {
  final int length;
  final int offset;
  const _HlsByteRange({required this.length, required this.offset});
  String get httpRangeHeader => 'bytes=$offset-${offset + length - 1}';
}

class _HlsMapInfo {
  final String uri;
  final _HlsByteRange? byteRange;
  const _HlsMapInfo({required this.uri, this.byteRange});

  String get identity =>
      byteRange == null ? uri : '$uri#${byteRange!.offset}:${byteRange!.length}';
}

class _HlsAudioRendition {
  final String groupId;
  final String name;
  final String language;
  final String? uri;
  final bool isDefault;
  final bool autoselect;
  const _HlsAudioRendition({
    required this.groupId,
    required this.name,
    required this.language,
    required this.uri,
    required this.isDefault,
    required this.autoselect,
  });
}

class _HlsSelectedVariant {
  final String videoUri;
  final int bandwidth;
  final String? audioGroupId;
  final String? audioUri;
  final String audioName;
  final String audioLanguage;
  final bool missingAudioGroup;
  const _HlsSelectedVariant({
    required this.videoUri,
    required this.bandwidth,
    this.audioGroupId,
    this.audioUri,
    this.audioName = '默认音轨',
    this.audioLanguage = '',
    this.missingAudioGroup = false,
  });
}

class _HlsSegment {
  final String uri;
  final String? keyMethod;
  final String? keyUri;
  final Uint8List? iv;
  final int sequence;
  final double duration;
  final bool discontinuity;
  final _HlsByteRange? byteRange;
  final _HlsMapInfo? map;
  const _HlsSegment({
    required this.uri,
    required this.keyMethod,
    required this.keyUri,
    required this.iv,
    required this.sequence,
    this.duration = 4.0,
    this.discontinuity = false,
    this.byteRange,
    this.map,
  });
}

class _HlsPlaylist {
  final List<_HlsSegment> segments;
  final String? mapUri;
  final _HlsMapInfo? firstMap;
  final int targetDuration;
  const _HlsPlaylist(
    this.segments,
    this.mapUri, {
    this.firstMap,
    this.targetDuration = 4,
  });
  bool get hasMap => mapUri != null || segments.any((s) => s.map != null);
}

class _HlsDownloadWorkItem {
  final String uri;
  final _HlsByteRange? byteRange;
  final String? keyMethod;
  final String? keyUri;
  final Uint8List? iv;
  final int sequence;
  final File stageFile;
  final bool isAudio;
  final bool isMap;
  final String trackName;
  final String playlistUrl;
  final String playlistHash;
  final String mapIdentity;
  final bool hasMap;
  const _HlsDownloadWorkItem({
    required this.uri,
    required this.stageFile,
    required this.isAudio,
    required this.trackName,
    required this.playlistUrl,
    required this.playlistHash,
    this.isMap = false,
    this.mapIdentity = '',
    this.hasMap = false,
    this.byteRange,
    this.keyMethod,
    this.keyUri,
    this.iv,
    this.sequence = 0,
  });

  String get stageFileName =>
      stageFile.uri.pathSegments.isNotEmpty ? stageFile.uri.pathSegments.last : '';

  String get resumeIdentity {
    final rangeStr =
        byteRange == null ? '' : '${byteRange!.offset}:${byteRange!.length}';
    final ivHex = iv == null
        ? ''
        : iv!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final keySig = '${keyMethod ?? ''}|${keyUri ?? ''}|$ivHex';
    final raw =
        'v2|$trackName|${isMap ? 'map' : 'seg'}|$playlistUrl|$playlistHash|$uri|$sequence|$rangeStr|$mapIdentity|$keySig';
    return sha256.convert(utf8.encode(raw)).toString();
  }
}

class _HlsStageManifest {
  static const int currentVersion = 2;
  final File file;
  final Map<String, Map<String, dynamic>> _entries;
  Future<void> _writeChain = Future<void>.value();

  _HlsStageManifest._(this.file, this._entries);

  static Future<_HlsStageManifest> load(Directory stageDir) async {
    final manifestFile = File(
      '${stageDir.path}${Platform.pathSeparator}stage_manifest.json',
    );
    final entries = <String, Map<String, dynamic>>{};
    try {
      if (await manifestFile.exists()) {
        final decoded = jsonDecode(await manifestFile.readAsString());
        if (decoded is Map &&
            decoded['version'] == currentVersion &&
            decoded['entries'] is Map) {
          (decoded['entries'] as Map).forEach((k, v) {
            if (k is String && v is Map) {
              entries[k] = Map<String, dynamic>.from(v);
            }
          });
        }
      }
    } catch (_) {}
    return _HlsStageManifest._(manifestFile, entries);
  }

  bool isReusableSync(
    _HlsDownloadWorkItem item, {
    required bool requirePositiveMedia,
  }) {
    final entry = _entries[item.stageFileName];
    if (entry == null) return false;
    if (entry['identity'] != item.resumeIdentity) return false;
    final expectedSize = entry['size'];
    if (expectedSize is! int || expectedSize <= 0) return false;
    if (!item.stageFile.existsSync()) return false;
    final actualSize = item.stageFile.lengthSync();
    if (actualSize != expectedSize) return false;
    if (item.byteRange != null) {
      final wantLen = item.byteRange!.length;
      if (wantLen <= 0) return false;
      if (item.keyMethod == 'AES-128') {
        if (actualSize > wantLen || wantLen - actualSize > 16) return false;
      } else if (actualSize != wantLen) {
        return false;
      }
    }
    try {
      final head = DownloadService._readHeadBytesSync(item.stageFile, 512);
      DownloadService._validateMediaPayload(
        head,
        contentType: '',
        isAudio: item.isAudio,
        isMap: item.isMap,
        hasMap: item.hasMap,
        requirePositiveMedia: requirePositiveMedia,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> pruneStale(
    Directory stageDir,
    List<_HlsDownloadWorkItem> items, {
    required bool requirePositiveMedia,
  }) async {
    final activeByName = <String, _HlsDownloadWorkItem>{
      for (final item in items) item.stageFileName: item,
    };
    var dirty = false;
    final manifestName =
        file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'stage_manifest.json';
    try {
      for (final entity in stageDir.listSync()) {
        if (entity is! File) continue;
        final name =
            entity.uri.pathSegments.isNotEmpty ? entity.uri.pathSegments.last : '';
        if (name == manifestName || name == '$manifestName.tmp') continue;
        final active = activeByName[name];
        if (active == null ||
            !isReusableSync(active, requirePositiveMedia: requirePositiveMedia)) {
          try {
            await entity.delete();
          } catch (_) {}
          if (_entries.remove(name) != null) {
            dirty = true;
          }
        }
      }
    } catch (_) {}
    final staleKeys = _entries.keys
        .where((k) => !activeByName.containsKey(k))
        .toList();
    for (final k in staleKeys) {
      _entries.remove(k);
      dirty = true;
    }
    if (dirty) {
      await _persist();
    }
  }

  /// Records a finished stage file. Persistence is coalesced: previously every
  /// segment re-encoded and rewrote the WHOLE manifest (including long signed
  /// URIs) and all workers awaited that serial write chain, which made
  /// downloads of long HLS playlists O(n²) in disk I/O and JSON CPU on the UI
  /// isolate. A segment missing from the manifest after a crash is simply
  /// re-downloaded, so batching is safe.
  Future<void> record(_HlsDownloadWorkItem item, int size) {
    _entries[item.stageFileName] = <String, dynamic>{
      'identity': item.resumeIdentity,
      'size': size,
      'track': item.trackName,
      'sequence': item.sequence,
    };
    _dirty = true;
    _persistTimer ??= Timer(persistInterval, () {
      _persistTimer = null;
      if (_dirty) unawaited(_persist());
    });
    return Future<void>.value();
  }

  static const Duration persistInterval = Duration(milliseconds: 1200);
  Timer? _persistTimer;
  bool _dirty = false;

  /// Writes any pending entries and waits for the write chain to drain.
  Future<void> flush() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_dirty) await _persist();
    await _writeChain;
  }

  Future<void> _persist() {
    _dirty = false;
    final snapshot = jsonEncode(<String, dynamic>{
      'version': currentVersion,
      'entries': Map<String, dynamic>.from(_entries),
    });
    _writeChain = _writeChain.then((_) async {
      try {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(snapshot);
        await tmp.rename(file.path);
      } catch (_) {}
    });
    return _writeChain;
  }
}

/// Offline download manager for iPhone / iPad / Mac / Windows.
///
/// - Direct files (`.mp4` / `.mkv` / ...) stream to disk with HTTP Range resume.
/// - HLS (`.m3u8`) picks the highest-bandwidth variant, downloads segments with
///   bounded parallelism (resumable per segment), decrypts `AES-128`, then merges
///   them into one `.ts` (or fMP4 `.mp4`) playable offline.
class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const int maxConcurrentTasks = 2;
  static const int segmentConcurrency = 6;

  /// Parallel ranged connections for one large direct (MP4/MKV…) file.
  static const int directConnections = 4;
  static const int _parallelDirectThreshold = 16 * 1024 * 1024;
  static const int _minDirectChunkBytes = 4 * 1024 * 1024;

  /// AES-128 segments at least this large are decrypted on a background
  /// isolate so the UI isolate (and its socket event loop) stays responsive.
  static const int _isolateDecryptThreshold = 192 * 1024;
  static const Duration _streamIdleTimeout = Duration(seconds: 45);
  static const String _defaultUa = 'okhttp/3.15';
  static const int _maxSegmentBytes = 96 * 1024 * 1024;

  final List<DownloadTask> _tasks = [];
  final Set<String> _running = {};
  final Set<String> _stopRequested = {};
  final Set<String> _deleteRequested = {};
  final Set<String> _sessionTouchedIds = {};
  final Set<String> _sessionRemovedIds = {};
  final Map<String, _Meter> _meters = {};
  List<DownloadTask>? _cachedSortedTasks;
  int _tasksSortCount = 0;
  CmsClient? _client;
  Directory? _root;
  File? _indexFile;
  bool _ready = false;
  bool _initialized = false;
  bool _initializing = false;
  Future<void>? _initFuture;
  Future<void>? _verificationFuture;
  int _restoreCount = 0;
  int _initEpoch = 0;
  Timer? _saveTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  @visibleForTesting
  Future<bool> Function(String path)? debugFileExistsProbe;

  @visibleForTesting
  Duration rootResolveTimeout = const Duration(seconds: 4);

  @visibleForTesting
  Duration fileVerifyTimeout = const Duration(seconds: 5);

  @visibleForTesting
  int maxVerifyConcurrency = 4;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    // 2 tasks × 6 segment workers share one keep-alive pool per host.
    ..maxConnectionsPerHost = maxConcurrentTasks * segmentConcurrency
    ..userAgent = null
    ..autoUncompress = false;

  bool get isReady => _ready;
  bool get isInitializing => _initializing;
  bool get isInitialized => _initialized;
  @visibleForTesting
  int get restoreCount => _restoreCount;
  @visibleForTesting
  int get tasksSortCount => _tasksSortCount;
  @visibleForTesting
  Future<void>? get verificationFuture => _verificationFuture;
  @visibleForTesting
  Future<void> flushSavesForTesting() => _saveChain;
  String get rootPath => _root?.path ?? '';
  bool get canOpenFolder =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  void _invalidateTasksCache() {
    _cachedSortedTasks = null;
  }

  /// Newest first for display (cached snapshot invalidated on queue mutation).
  List<DownloadTask> get tasks {
    final cached = _cachedSortedTasks;
    if (cached != null) return cached;
    _tasksSortCount++;
    final list = List<DownloadTask>.of(_tasks);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final frozen = List<DownloadTask>.unmodifiable(list);
    _cachedSortedTasks = frozen;
    return frozen;
  }

  int get activeCount => _tasks.where((t) => t.isActive).length;

  @visibleForTesting
  CmsClient? get debugClient => _client;

  /// Restores persisted download records at most once without blocking UI on
  /// per-file synchronous disk probes. Completed files are verified
  /// asynchronously with bounded concurrency after the queue is live.
  Future<void> init(CmsClient client) {
    _client = client;
    if (_initialized) return Future<void>.value();
    final pending = _initFuture;
    if (pending != null) {
      if (identical(Zone.current, _initFutureZone)) return pending;
      // Avoid deadlocking when a different Zone (e.g. testWidgets runAsync)
      // awaits an in-flight Future whose continuations belong to a paused Zone.
      final epoch = ++_initEpoch;
      _initializing = true;
      _initFutureZone = Zone.current;
      final future = _performInit(epoch);
      _initFuture = future;
      return future;
    }
    _initializing = true;
    final epoch = ++_initEpoch;
    _initFutureZone = Zone.current;
    final future = _performInit(epoch);
    _initFuture = future;
    return future;
  }

  Zone? _initFutureZone;

  Future<void> _performInit(int epoch) async {
    final completedToVerify = <DownloadTask>[];
    var indexCorrupted = false;
    final rootFuture = _resolveRoot().then<Directory?>(
      (dir) => dir,
      onError: (_) => null,
    );
    try {
      final support = await getApplicationSupportDirectory();
      if (epoch != _initEpoch) return;
      await support.create(recursive: true);
      if (epoch != _initEpoch) return;
      _indexFile = File(_join(support.path, 'marco_downloads.json'));
      if (await _indexFile!.exists()) {
        try {
          final raw = await _indexFile!.readAsString();
          if (epoch != _initEpoch) return;
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            var mutatedAny = false;
            for (final item in decoded) {
              if (item is! Map) continue;
              final task = DownloadTask.fromJson(
                Map<String, dynamic>.from(item),
              );
              if (task.id.isEmpty) continue;
              if (_sessionRemovedIds.contains(task.id)) continue;
              final existingIdx = _tasks.indexWhere((t) => t.id == task.id);
              if (existingIdx >= 0) {
                final existing = _tasks[existingIdx];
                // Preserve completed offline record & filePath if user clicked
                // download on the same episode while disk index was restoring.
                if (task.status == DownloadStatus.completed &&
                    task.filePath.isNotEmpty &&
                    existing.status != DownloadStatus.completed &&
                    !_running.contains(existing.id)) {
                  _tasks[existingIdx] = task;
                  completedToVerify.add(task);
                  mutatedAny = true;
                }
                continue;
              }
              if (task.status == DownloadStatus.downloading) {
                task.status = DownloadStatus.queued;
              }
              if (task.status == DownloadStatus.completed) {
                completedToVerify.add(task);
              }
              _tasks.add(task);
              mutatedAny = true;
            }
            if (mutatedAny) {
              _invalidateTasksCache();
              notifyListeners();
            }
          } else {
            indexCorrupted = true;
          }
        } catch (e) {
          indexCorrupted = true;
          debugPrint('DownloadService index parse error: $e');
        }
      }
      if (!indexCorrupted) {
        _restoreCount++;
      }
      final resolvedRoot = await rootFuture;
      if (epoch != _initEpoch) return;
      _root = resolvedRoot;
    } catch (e) {
      debugPrint('DownloadService init: $e');
    }
    if (epoch != _initEpoch) return;
    _ready = _root != null;
    if (_ready && !indexCorrupted) {
      _initialized = true;
    } else {
      // Allow subsequent init() retries after index repair or drive recovery.
      _initialized = false;
      _initFuture = null;
    }
    _initializing = false;
    if (!indexCorrupted &&
        (_sessionTouchedIds.isNotEmpty || _sessionRemovedIds.isNotEmpty)) {
      _scheduleSave(immediate: true);
    }
    notifyListeners();
    _pump();
    if (completedToVerify.isNotEmpty) {
      _verificationFuture = _verifyCompletedFilesInBackground(
        completedToVerify,
        epoch,
      );
    } else {
      _verificationFuture = Future<void>.value();
    }
  }

  /// Returns `true` if the file exists, `false` if definitively absent, or
  /// `null` when verification timed out / encountered transient I/O errors
  /// (so slow/disconnected disks never falsely mark valid downloads as failed).
  Future<bool?> _checkFileExists(String path) async {
    if (path.isEmpty) return false;
    final probe = debugFileExistsProbe;
    if (probe != null) {
      try {
        return await probe(path).timeout(fileVerifyTimeout);
      } on TimeoutException {
        return null;
      } catch (_) {
        return null;
      }
    }
    try {
      return await File(path).exists().timeout(fileVerifyTimeout);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _verifyCompletedFilesInBackground(
    List<DownloadTask> candidates,
    int epoch,
  ) async {
    if (candidates.isEmpty) return;
    final concurrency = maxVerifyConcurrency < 1 ? 1 : maxVerifyConcurrency;
    final workerCount =
        candidates.length < concurrency ? candidates.length : concurrency;
    var nextIndex = 0;
    var mutated = false;

    Future<void> worker() async {
      while (true) {
        if (epoch != _initEpoch) return;
        final idx = nextIndex++;
        if (idx >= candidates.length) return;
        final task = candidates[idx];
        if (task.status != DownloadStatus.completed ||
            !_tasks.contains(task)) {
          continue;
        }
        final exists = await _checkFileExists(task.filePath);
        if (epoch != _initEpoch) return;
        if (exists == false &&
            task.status == DownloadStatus.completed &&
            _tasks.contains(task)) {
          task.status = DownloadStatus.failed;
          task.error = '本地文件已被移动或删除';
          task.progress = 0;
          mutated = true;
        }
      }
    }

    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    if (epoch != _initEpoch) return;
    if (mutated) {
      _invalidateTasksCache();
      _scheduleSave(immediate: true);
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTesting() {
    _initEpoch++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _tasks.clear();
    _running.clear();
    _stopRequested.clear();
    _deleteRequested.clear();
    _sessionTouchedIds.clear();
    _sessionRemovedIds.clear();
    _meters.clear();
    _cachedSortedTasks = null;
    _tasksSortCount = 0;
    _client = null;
    _root = null;
    _indexFile = null;
    _ready = false;
    _initialized = false;
    _initializing = false;
    _initFuture = null;
    _initFutureZone = null;
    _verificationFuture = null;
    _restoreCount = 0;
    debugFileExistsProbe = null;
    rootResolveTimeout = const Duration(seconds: 4);
    fileVerifyTimeout = const Duration(seconds: 5);
    maxVerifyConcurrency = 4;
  }

  /// Simulates a clean app restart in tests by reloading persisted task state
  /// from disk without altering any downloaded files.
  @visibleForTesting
  Future<void> reloadFromDiskForTest(CmsClient client) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _save();
    _initEpoch++;
    _tasks.clear();
    _running.clear();
    _stopRequested.clear();
    _deleteRequested.clear();
    _sessionTouchedIds.clear();
    _sessionRemovedIds.clear();
    _meters.clear();
    _invalidateTasksCache();
    _initialized = false;
    _initializing = false;
    _initFuture = null;
    _initFutureZone = null;
    await init(client);
  }

  static bool _verifyCompletedFilesExist(DownloadTask task) =>
      _diagnoseCompletedFilesIssue(task) == null;

  static String? _diagnoseCompletedFilesIssue(DownloadTask task) {
    if (task.filePath.isEmpty) return '本地文件已被移动或删除';
    final master = File(task.filePath);
    if (!master.existsSync() || master.lengthSync() <= 0) {
      return '本地文件已被移动或删除';
    }
    if (!task.filePath.toLowerCase().endsWith('.m3u8')) return null;
    final rootNorm = _normalizedPath(master.parent.path);
    return _diagnoseLocalPlaylistTreeSync(
      playlistFile: master,
      rootNorm: rootNorm,
      visited: <String>{},
      depth: 0,
      isAudioHint: false,
    );
  }

  static File? _resolveLocalPlaylistRef(
    Directory baseDir,
    String rawRef,
    String rootNorm,
  ) {
    final clean = rawRef.trim().split('?').first.split('#').first;
    if (clean.isEmpty) return null;
    if (clean.contains('://')) return null;
    final rel = clean.replaceAll('/', Platform.pathSeparator);
    final candidate = File(_join(baseDir.path, rel));
    final norm = _normalizedPath(candidate.path);
    if (norm != rootNorm && !norm.startsWith('$rootNorm/')) {
      return null;
    }
    return candidate;
  }

  static String? _diagnoseLocalPlaylistTreeSync({
    required File playlistFile,
    required String rootNorm,
    required Set<String> visited,
    required int depth,
    required bool isAudioHint,
  }) {
    final trackLabel = isAudioHint ? '音轨' : '视频轨';
    if (depth > 4) return '离线$trackLabel清单层级异常，请重新下载';
    final playlistNorm = _normalizedPath(playlistFile.path);
    if (!visited.add(playlistNorm)) return '离线$trackLabel清单引用异常，请重新下载';
    try {
      if (!playlistFile.existsSync() || playlistFile.lengthSync() <= 0) {
        return '离线$trackLabel清单缺失或损坏，请重新下载';
      }
      final content = playlistFile.readAsStringSync();
      if (!content.trimLeft().replaceFirst('\uFEFF', '').startsWith('#EXTM3U')) {
        return '离线$trackLabel清单内容损坏，请重新下载';
      }
      final lines = const LineSplitter().convert(content);
      final isMaster = lines.any((l) {
        final t = l.trim();
        return t.startsWith('#EXT-X-STREAM-INF:') ||
            t.startsWith('#EXT-X-MEDIA:');
      });
      final baseDir = playlistFile.parent;
      var hasMapTag = false;
      var referencedCount = 0;
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXT-X-MEDIA:')) {
          final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
          final uri = attrs['URI'];
          if (uri != null && uri.isNotEmpty) {
            final sub = _resolveLocalPlaylistRef(baseDir, uri, rootNorm);
            final mediaType = (attrs['TYPE'] ?? '').toUpperCase();
            final subIsAudio = mediaType == 'AUDIO';
            if (sub == null) {
              return '离线${subIsAudio ? "音轨" : "媒体"}清单路径无效，请重新下载';
            }
            referencedCount++;
            final subIssue = _diagnoseLocalPlaylistTreeSync(
              playlistFile: sub,
              rootNorm: rootNorm,
              visited: visited,
              depth: depth + 1,
              isAudioHint: subIsAudio,
            );
            if (subIssue != null) return subIssue;
          }
          continue;
        }
        if (line.startsWith('#EXT-X-MAP:')) {
          hasMapTag = true;
          final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
          final uri = attrs['URI'];
          if (uri == null || uri.isEmpty) {
            return '离线$trackLabel初始化段缺失，请重新下载';
          }
          final mapFile = _resolveLocalPlaylistRef(baseDir, uri, rootNorm);
          if (mapFile == null ||
              !mapFile.existsSync() ||
              mapFile.lengthSync() <= 0) {
            return '离线$trackLabel初始化段缺失或损坏，请重新下载';
          }
          final head = _readHeadBytesSync(mapFile, 512);
          _validateMediaPayload(
            head,
            contentType: '',
            isAudio: isAudioHint,
            isMap: true,
            hasMap: true,
            requirePositiveMedia: true,
          );
          continue;
        }
        if (line.startsWith('#')) continue;
        final refFile = _resolveLocalPlaylistRef(baseDir, line, rootNorm);
        if (refFile == null) return '离线$trackLabel分片路径无效，请重新下载';
        referencedCount++;
        if (isMaster || line.toLowerCase().endsWith('.m3u8')) {
          final subIssue = _diagnoseLocalPlaylistTreeSync(
            playlistFile: refFile,
            rootNorm: rootNorm,
            visited: visited,
            depth: depth + 1,
            isAudioHint: isAudioHint,
          );
          if (subIssue != null) return subIssue;
        } else {
          if (!refFile.existsSync() || refFile.lengthSync() <= 0) {
            return '离线$trackLabel分片缺失或损坏，请重新下载';
          }
          final head = _readHeadBytesSync(refFile, 512);
          _validateMediaPayload(
            head,
            contentType: '',
            isAudio: isAudioHint,
            isMap: false,
            hasMap: hasMapTag,
            requirePositiveMedia: true,
          );
        }
      }
      return referencedCount > 0 ? null : '离线$trackLabel分片列表为空，请重新下载';
    } on _DownloadError catch (e) {
      return e.message;
    } catch (_) {
      return '离线$trackLabel分片缺失或损坏，请重新下载';
    }
  }

  static Future<T> _withWallClockTimeout<T>(
    Future<T> future,
    Duration timeout,
  ) {
    final completer = Completer<T>();
    final timer = Zone.root.createTimer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Timed out', timeout));
      }
    });
    future.then(
      (value) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  Future<Directory> _resolveRoot() async {
    Directory? base;
    final isDesktopTarget = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (!kIsWeb &&
        isDesktopTarget &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        base = await _withWallClockTimeout(
          getDownloadsDirectory(),
          rootResolveTimeout,
        );
        if (base != null) {
          final probe = Directory(_join(base.path, 'Marco Movie'));
          await _withWallClockTimeout(
            probe.create(recursive: true),
            rootResolveTimeout,
          );
          return probe;
        }
      } catch (_) {
        base = null;
      }
    }
    base = await getApplicationDocumentsDirectory();
    final dir = Directory(_join(base.path, 'Marco Movie'));
    await dir.create(recursive: true);
    return dir;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Adds episodes of [line] to the queue; returns how many were (re)queued.
  int enqueue({
    required CmsSite site,
    required CmsVideo video,
    required CmsLine line,
    required List<int> episodeIndexes,
    List<CmsParse> parses = const [],
  }) {
    var added = 0;
    for (final idx in episodeIndexes) {
      if (idx < 0 || idx >= line.episodes.length) continue;
      final ep = line.episodes[idx];
      final id = _taskId(site.key, video.id, line.name, idx, ep.url);
      _sessionTouchedIds.add(id);
      _sessionRemovedIds.remove(id);
      final existing = _byId(id);
      if (existing != null) {
        if (existing.status == DownloadStatus.failed ||
            existing.status == DownloadStatus.paused) {
          existing.status = DownloadStatus.queued;
          existing.error = '';
          added++;
        }
        continue;
      }
      _tasks.add(
        DownloadTask(
          id: id,
          siteKey: site.key,
          siteName: site.name,
          siteApi: site.api,
          siteType: site.type,
          videoId: video.id,
          title: video.title.isEmpty ? '未命名影片' : video.title,
          poster: video.poster,
          lineName: line.name,
          episodeName: ep.name.isEmpty ? '第 ${idx + 1} 集' : ep.name,
          episodeIndex: idx,
          sourceUrl: ep.url,
          headers: Map.of(ep.headers),
          sourceSite: site,
          sourceParses: List.unmodifiable(parses),
          createdAt: DateTime.now().millisecondsSinceEpoch + added,
        ),
      );
      added++;
    }
    if (added > 0) {
      _invalidateTasksCache();
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
    return added;
  }

  DownloadTask? taskFor(String siteKey, String videoId, String lineName, int index) {
    for (final t in _tasks) {
      if (t.siteKey == siteKey &&
          t.videoId == videoId &&
          t.lineName == lineName &&
          t.episodeIndex == index) {
        return t;
      }
    }
    return null;
  }

  /// Completed episodes of one video, ordered by episode index (for offline playback).
  List<DownloadTask> completedFor(String siteKey, String videoId) {
    final list = _tasks
        .where((t) =>
            t.siteKey == siteKey &&
            t.videoId == videoId &&
            t.status == DownloadStatus.completed)
        .toList();
    list.sort((a, b) => a.episodeIndex.compareTo(b.episodeIndex));
    return list;
  }

  void pause(String id) {
    final t = _byId(id);
    if (t == null) return;
    _sessionTouchedIds.add(id);
    if (_running.contains(id)) {
      _stopRequested.add(id);
    } else if (t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.paused;
    }
    _scheduleSave(immediate: true);
    notifyListeners();
  }

  void resume(String id) {
    final t = _byId(id);
    if (t == null) return;
    _sessionTouchedIds.add(id);
    if (t.status == DownloadStatus.paused || t.status == DownloadStatus.failed) {
      t.status = DownloadStatus.queued;
      t.error = '';
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
  }

  void pauseAll() {
    for (final t in _tasks) {
      if (t.isActive) pause(t.id);
    }
  }

  /// Pauses every active task in [ids] (e.g. one series) with one save/notify.
  void pauseTasks(Iterable<String> ids) {
    var changed = false;
    for (final id in ids.toSet()) {
      final t = _byId(id);
      if (t == null || !t.isActive) continue;
      if (_running.contains(id)) {
        _stopRequested.add(id);
      } else {
        t.status = DownloadStatus.paused;
      }
      changed = true;
    }
    if (!changed) return;
    _scheduleSave(immediate: true);
    notifyListeners();
  }

  /// Re-queues every paused / failed task in [ids] with one save/notify.
  void resumeTasks(Iterable<String> ids) {
    var changed = false;
    for (final id in ids.toSet()) {
      final t = _byId(id);
      if (t == null) continue;
      if (t.status == DownloadStatus.paused || t.status == DownloadStatus.failed) {
        t.status = DownloadStatus.queued;
        t.error = '';
        changed = true;
      }
    }
    if (!changed) return;
    _scheduleSave(immediate: true);
    notifyListeners();
    _pump();
  }

  /// Removes every task in [ids] (and its files) with one immediate UI update.
  Future<void> removeTasks(Iterable<String> ids) async {
    final toDelete = <DownloadTask>[];
    var changed = false;
    for (final id in ids.toSet()) {
      _sessionRemovedIds.add(id);
      _sessionTouchedIds.remove(id);
      final t = _byId(id);
      if (t == null) continue;
      _tasks.remove(t);
      changed = true;
      if (_running.contains(id)) {
        _stopRequested.add(id);
        _deleteRequested.add(id);
      } else {
        toDelete.add(t);
      }
    }
    if (!changed) return;
    _invalidateTasksCache();
    _scheduleSave(immediate: true);
    notifyListeners();
    for (final t in toDelete) {
      await _deleteFiles(t);
    }
  }

  void resumeAll() {
    for (final t in _tasks) {
      if (t.status == DownloadStatus.paused) {
        _sessionTouchedIds.add(t.id);
        t.status = DownloadStatus.queued;
      }
    }
    _scheduleSave(immediate: true);
    notifyListeners();
    _pump();
  }

  Future<void> remove(String id) async {
    _sessionRemovedIds.add(id);
    _sessionTouchedIds.remove(id);
    final t = _byId(id);
    if (t == null) return;
    _tasks.remove(t);
    _invalidateTasksCache();
    if (_running.contains(id)) {
      _stopRequested.add(id);
      _deleteRequested.add(id);
    } else {
      await _deleteFiles(t);
    }
    _scheduleSave(immediate: true);
    notifyListeners();
  }

  Future<void> openFolder() async {
    final path = rootPath;
    if (path.isEmpty || !canOpenFolder) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  static String formatBytes(num bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String statusLabel(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
        return '等待中';
      case DownloadStatus.downloading:
        final pct = (t.progress * 100).clamp(0, 100).toStringAsFixed(0);
        final speed = t.speed > 0 ? ' · ${formatBytes(t.speed)}/s' : '';
        return '下载中 $pct%$speed';
      case DownloadStatus.paused:
        return '已暂停 ${(t.progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
      case DownloadStatus.completed:
        return '已完成 · ${formatBytes(t.totalBytes)}';
      case DownloadStatus.failed:
        return t.error.isEmpty ? '下载失败' : '失败：${t.error}';
    }
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  DownloadTask? _byId(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _pump() {
    if (!_ready) return;
    for (final t in List<DownloadTask>.of(_tasks)) {
      if (_running.length >= maxConcurrentTasks) break;
      if (t.status == DownloadStatus.queued && !_running.contains(t.id)) {
        _running.add(t.id);
        unawaited(_run(t));
      }
    }
  }

  bool _shouldStop(DownloadTask t) => _stopRequested.contains(t.id);

  Future<void> _run(DownloadTask t) async {
    t.status = DownloadStatus.downloading;
    t.error = '';
    t.speed = 0;
    _meters[t.id] = _Meter(t._wireBytes, DateTime.now());
    notifyListeners();
    try {
      final client = _client ?? CmsClient();
      final site = t.sourceSite ?? CmsSite(
        key: t.siteKey,
        name: t.siteName,
        type: t.siteType,
        api: t.siteApi,
      );
      // Legacy tasks mixed source credentials into media headers. They may only
      // inherit those credentials within the original source origin.
      final mediaHeaders = t.sourceSite == null
          ? headersForOrigin(t.headers, Uri.tryParse(t.siteApi), Uri.tryParse(t.sourceUrl))
          : t.headers;
      final episode = await client.resolveEpisodeForPlayback(
        site,
        CmsEpisode(name: t.episodeName, url: t.sourceUrl, headers: mediaHeaders),
        parses: t.sourceParses,
      );
      final headers = Map<String, String>.of(episode.headers);
      final url = episode.url.trim();
      t._credentialOrigin = Uri.tryParse(url);
      t._redirectedUrls.clear();
      final lower = url.toLowerCase();
      if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        throw const _DownloadError('该剧集不是可下载的视频直链');
      }
      final dir = _taskDirectory(t);
      await dir.create(recursive: true);
      final baseName = _join(dir.path, _safeName('${t.episodeName}_${t.lineName}'));
      if (_looksLikeHls(url)) {
        await _downloadHls(t, url, headers, baseName, null);
      } else {
        await _downloadDirect(t, url, headers, baseName);
      }
      if (_shouldStop(t)) {
        t.status = DownloadStatus.paused;
      } else {
        t.status = DownloadStatus.completed;
        t.progress = 1;
      }
    } on _StopSignal {
      t.status = DownloadStatus.paused;
    } catch (e) {
      if (_shouldStop(t)) {
        t.status = DownloadStatus.paused;
      } else {
        t.status = DownloadStatus.failed;
        t.error = _friendlyError(e);
      }
    } finally {
      t.speed = 0;
      _running.remove(t.id);
      _stopRequested.remove(t.id);
      _meters.remove(t.id);
      if (_deleteRequested.remove(t.id)) {
        await _deleteFiles(t);
      }
      _scheduleSave(immediate: true);
      notifyListeners();
      _pump();
    }
  }

  void _onProgress(DownloadTask t) {
    final now = DateTime.now();
    final meter = _meters.putIfAbsent(t.id, () => _Meter(t._wireBytes, now));
    final elapsed = now.difference(meter.time).inMilliseconds;
    if (elapsed >= 800) {
      var instant = (t._wireBytes - meter.bytes) * 1000 / elapsed;
      if (instant < 0) instant = 0;
      // Light smoothing so parallel segment bursts don't make the label jump.
      t.speed = t.speed <= 0 ? instant : t.speed * 0.35 + instant * 0.65;
      meter.bytes = t._wireBytes;
      meter.time = now;
    }
    // UI notifications stay throttled to ~4 Hz regardless of chunk rate.
    if (now.difference(_lastNotify).inMilliseconds >= 250) {
      _lastNotify = now;
      notifyListeners();
      _scheduleSave();
    }
  }

  void _scheduleSave({bool immediate = false}) {
    if (immediate) {
      _saveTimer?.cancel();
      _saveTimer = null;
      unawaited(_save());
      return;
    }
    _saveTimer ??= Timer(const Duration(seconds: 3), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _saveChain = Future<void>.value();

  Future<void> _save() {
    final epoch = _initEpoch;
    _saveChain = _saveChain.then((_) async {
      if (epoch != _initEpoch) return;
      final file = _indexFile;
      if (file == null) return;
      try {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(
          jsonEncode(_tasks.map((t) => t.toJson()).toList()),
        );
        await tmp.rename(file.path);
      } catch (_) {}
    });
    return _saveChain;
  }

  Future<void> _deleteFiles(DownloadTask t) async {
    final root = _root;
    if (root == null) return;
    // Keep legacy files still referenced by another task. Never infer ownership
    // of an old partial file from a display name shared by multiple tasks.
    final path = t.filePath;
    if (path.isNotEmpty && _underRoot(path) &&
        !_tasks.any((other) => _normalizedPath(other.filePath) == _normalizedPath(path))) {
      try { final file = File(path); if (await file.exists()) await file.delete(); } catch (_) {}
    }
    final dir = _taskDirectory(t);
    if (_underRoot(dir.path) && !_tasks.any((other) => other.id == t.id)) {
      try { if (await dir.exists()) await dir.delete(recursive: true); } catch (_) {}
    }
  }

  Directory _taskDirectory(DownloadTask t) =>
      Directory(_join(_join(_root!.path, '_tasks'), _safeName(t.id)));

  static String _normalizedPath(String path) {
    if (path.isEmpty) return '';
    final normalized = File(path).absolute.uri.normalizePath().toFilePath()
        .replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _underRoot(String path) =>
      _normalizedPath(path).startsWith('${_normalizedPath(_root!.path)}/');

  // ---------------------------------------------------------------------------
  // Direct file download
  // ---------------------------------------------------------------------------

  Future<void> _downloadDirect(
    DownloadTask t,
    String url,
    Map<String, String> headers,
    String baseName, {
    bool allowParallel = true,
  }) async {
    final ext = _extFromUrl(url, fallback: '.mp4');
    final finalFile = File('$baseName$ext');
    final part = File('$baseName$ext.part');
    final partsDir = Directory('$baseName$ext.parts');
    if (await partsDir.exists()) {
      final meta = allowParallel ? await _readParallelMeta(partsDir) : null;
      if (meta != null) {
        try {
          await _downloadDirectParallel(
            t,
            url,
            headers,
            finalFile: finalFile,
            partsDir: partsDir,
            total: meta.total,
            parts: meta.parts,
          );
          return;
        } on _ParallelRangeUnsupported {
          await _deleteDirQuietly(partsDir);
          return _downloadDirect(t, url, headers, baseName, allowParallel: false);
        }
      }
      await _deleteDirQuietly(partsDir);
    }
    var existing = await part.exists() ? await part.length() : 0;
    final response = await _open(url, headers, t,
        range: existing > 0 ? 'bytes=$existing-' : null);
    if (response.statusCode == 416 && existing > 0) {
      await response.drain<void>();
      await part.delete();
      return _downloadDirect(t, url, headers, baseName,
          allowParallel: allowParallel);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw _DownloadError('服务器返回 HTTP ${response.statusCode}');
    }
    final mime = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (mime.contains('text/html')) {
      await response.drain<void>();
      throw const _DownloadError('该地址返回的是网页，无法直接下载');
    }
    final append = response.statusCode == 206 && existing > 0;
    if (append) {
      final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
          .firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      if (match == null || int.parse(match[1]!) != existing) {
        await response.drain<void>();
        throw const _DownloadError('续传范围不匹配，请重新下载');
      }
    }
    if (!append) existing = 0;
    final contentLength = response.contentLength;
    if (!append &&
        allowParallel &&
        response.statusCode == 200 &&
        _supportsParallelRanges(response, mime, contentLength)) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      try {
        await _downloadDirectParallel(
          t,
          url,
          headers,
          finalFile: finalFile,
          partsDir: partsDir,
          total: contentLength,
          parts: math.max(
            1,
            math.min(directConnections, contentLength ~/ _minDirectChunkBytes),
          ),
          initial: response,
        );
        return;
      } on _ParallelRangeUnsupported {
        await _deleteDirQuietly(partsDir);
        return _downloadDirect(t, url, headers, baseName, allowParallel: false);
      }
    }
    t.totalBytes = contentLength > 0 ? existing + contentLength : 0;
    t.receivedBytes = existing;
    BytesBuilder? playlistBuffer;
    var firstChunk = true;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response.timeout(_streamIdleTimeout)) {
        if (_shouldStop(t)) throw const _StopSignal();
        if (firstChunk) {
          firstChunk = false;
          if (!append && (mime.contains('mpegurl') || _startsWithM3u(chunk))) {
            playlistBuffer = BytesBuilder(copy: false);
          }
        }
        if (playlistBuffer != null) {
          playlistBuffer.add(chunk);
          if (playlistBuffer.length > 8 * 1024 * 1024) {
            throw const _DownloadError('播放列表过大');
          }
          continue;
        }
        sink.add(chunk);
        t.receivedBytes += chunk.length;
        t._wireBytes += chunk.length;
        if (t.totalBytes > 0) {
          t.progress = (t.receivedBytes / t.totalBytes).clamp(0.0, 1.0);
        }
        _onProgress(t);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (playlistBuffer != null) {
      try {
        await part.delete();
      } catch (_) {}
      final text = utf8.decode(playlistBuffer.takeBytes(), allowMalformed: true);
      await _downloadHls(t, t._redirectedUrls[url] ?? url, headers, baseName, text);
      return;
    }
    if (t.totalBytes > 0 && t.receivedBytes < t.totalBytes) {
      throw const _DownloadError('连接中断，可点击继续下载');
    }
    if (t.receivedBytes <= 0) {
      throw const _DownloadError('服务器没有返回任何数据');
    }
    if (await finalFile.exists()) await finalFile.delete();
    await part.rename(finalFile.path);
    t.filePath = finalFile.path;
    t.totalBytes = t.receivedBytes;
  }

  static bool _supportsParallelRanges(
    HttpClientResponse response,
    String mime,
    int contentLength,
  ) {
    if (contentLength < _parallelDirectThreshold) return false;
    if (mime.contains('mpegurl') || mime.startsWith('text/')) return false;
    final ranges =
        (response.headers.value(HttpHeaders.acceptRangesHeader) ?? '').toLowerCase();
    if (!ranges.contains('bytes')) return false;
    final encoding =
        (response.headers.value(HttpHeaders.contentEncodingHeader) ?? '')
            .trim()
            .toLowerCase();
    return encoding.isEmpty || encoding == 'identity';
  }

  static Future<({int total, int parts})?> _readParallelMeta(
    Directory partsDir,
  ) async {
    try {
      final file = File(_join(partsDir.path, 'meta.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return null;
      final total = decoded['total'];
      final parts = decoded['parts'];
      if (total is! int || parts is! int) return null;
      if (total <= 0 || parts < 1 || parts > 8) return null;
      return (total: total, parts: parts);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _deleteDirQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Downloads one large Range-capable file over [parts] parallel connections
  /// (CDNs commonly cap the throughput of each TCP stream). Each range streams
  /// to its own `part_i` file, so pause / crash resume continues every range
  /// from its own offset; the parts are concatenated in order at the end.
  Future<void> _downloadDirectParallel(
    DownloadTask t,
    String url,
    Map<String, String> headers, {
    required File finalFile,
    required Directory partsDir,
    required int total,
    required int parts,
    HttpClientResponse? initial,
  }) async {
    var initialConsumed = initial == null;
    try {
      await partsDir.create(recursive: true);
      await File(_join(partsDir.path, 'meta.json')).writeAsString(
        jsonEncode(<String, dynamic>{'version': 1, 'total': total, 'parts': parts}),
      );
      final starts = List<int>.generate(parts, (i) => total * i ~/ parts);
      final ends = List<int>.generate(parts, (i) => total * (i + 1) ~/ parts - 1);
      final files = List<File>.generate(
        parts,
        (i) => File(_join(partsDir.path, 'part_$i')),
      );
      var received = 0;
      for (var i = 0; i < parts; i++) {
        final size = ends[i] - starts[i] + 1;
        var have = await files[i].exists() ? await files[i].length() : 0;
        if (have > size) {
          await files[i].delete();
          have = 0;
        }
        received += have;
      }
      t.totalBytes = total;
      t.receivedBytes = received;
      t.progress = (received / total).clamp(0.0, 1.0);
      notifyListeners();

      Object? failure;
      void account(int n) {
        t.receivedBytes += n;
        t._wireBytes += n;
        t.progress = (t.receivedBytes / total).clamp(0.0, 1.0);
        _onProgress(t);
      }

      Future<int> pump(int i, int have, HttpClientResponse response) async {
        final need = ends[i] - starts[i] + 1 - have;
        var got = 0;
        final sink = files[i].openWrite(mode: FileMode.append);
        try {
          await for (final chunk in response.timeout(_streamIdleTimeout)) {
            if (_shouldStop(t) || failure != null) break;
            final remain = need - got;
            if (chunk.length >= remain) {
              sink.add(chunk.length == remain
                  ? chunk
                  : (chunk is Uint8List
                      ? Uint8List.sublistView(chunk, 0, remain)
                      : chunk.sublist(0, remain)));
              got += remain;
              account(remain);
              break; // Cancels the subscription; the rest belongs to range i+1.
            }
            sink.add(chunk);
            got += chunk.length;
            account(chunk.length);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        return got;
      }

      Future<void> worker(int i) async {
        final size = ends[i] - starts[i] + 1;
        var attempts = 0;
        try {
          var have = await files[i].exists() ? await files[i].length() : 0;
          while (have < size) {
            if (_shouldStop(t) || failure != null) return;
            HttpClientResponse response;
            if (i == 0 && !initialConsumed && have == 0) {
              initialConsumed = true;
              response = initial!;
            } else {
              final from = starts[i] + have;
              try {
                response = await _open(url, headers, t,
                    range: 'bytes=$from-${ends[i]}');
              } on _StopSignal {
                rethrow;
              } on _DownloadError {
                rethrow;
              } catch (e) {
                if (++attempts > 3) rethrow;
                await Future<void>.delayed(Duration(milliseconds: 600 * attempts));
                continue;
              }
              if (response.statusCode != 206) {
                await _discardResponse(response);
                if (response.statusCode >= 500 || response.statusCode == 429) {
                  if (++attempts > 3) {
                    throw _DownloadError('服务器返回 HTTP ${response.statusCode}');
                  }
                  await Future<void>.delayed(Duration(milliseconds: 600 * attempts));
                  continue;
                }
                throw const _ParallelRangeUnsupported();
              }
              final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
                      caseSensitive: false)
                  .firstMatch(
                      (response.headers.value(HttpHeaders.contentRangeHeader) ?? '')
                          .trim());
              final respStart = match == null ? null : int.tryParse(match[1]!);
              final respTotal = match == null ? null : int.tryParse(match[3]!);
              if (respStart != from || (respTotal != null && respTotal != total)) {
                await _discardResponse(response);
                throw const _ParallelRangeUnsupported();
              }
            }
            int got;
            try {
              got = await pump(i, have, response);
            } on _StopSignal {
              rethrow;
            } catch (e) {
              if (_shouldStop(t) || failure != null) return;
              if (++attempts > 3) rethrow;
              await Future<void>.delayed(Duration(milliseconds: 600 * attempts));
              have = await files[i].length();
              continue;
            }
            have = await files[i].length();
            if (got > 0) {
              attempts = 0;
            } else if (!_shouldStop(t) && failure == null && ++attempts > 3) {
              throw const _DownloadError('连接中断，可点击继续下载');
            }
          }
        } catch (e) {
          failure ??= e;
        }
      }

      await Future.wait([for (var i = 0; i < parts; i++) worker(i)]);
      if (_shouldStop(t)) throw const _StopSignal();
      if (failure != null) throw failure!;

      for (var i = 0; i < parts; i++) {
        final size = ends[i] - starts[i] + 1;
        if (!await files[i].exists() || await files[i].length() != size) {
          throw const _DownloadError('分段下载不完整，可点击继续下载');
        }
      }
      final out = File('${finalFile.path}.part');
      final sink = out.openWrite();
      try {
        for (final f in files) {
          if (_shouldStop(t)) throw const _StopSignal();
          await sink.addStream(f.openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await out.length() != total) {
        throw const _DownloadError('合并后的文件大小异常，请重新下载');
      }
      if (await finalFile.exists()) await finalFile.delete();
      await out.rename(finalFile.path);
      await _deleteDirQuietly(partsDir);
      t.filePath = finalFile.path;
      t.totalBytes = total;
      t.receivedBytes = total;
    } finally {
      if (!initialConsumed && initial != null) {
        await _discardResponse(initial);
      }
    }
  }

  static Future<void> _discardResponse(HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // HLS download
  // ---------------------------------------------------------------------------

  Future<void> _downloadHls(
    DownloadTask t,
    String url,
    Map<String, String> headers,
    String baseName,
    String? preloaded,
  ) async {
    var playlistUrl = url;
    var text = preloaded ?? await _getText(playlistUrl, headers, t);
    playlistUrl = t._redirectedUrls[playlistUrl] ?? playlistUrl;
    String? selectedAudioUri;
    var selectedAudioName = '默认音轨';
    var selectedAudioLanguage = '';
    var selectedBandwidth = 0;
    for (var depth = 0; depth < 4 && text.contains('#EXT-X-STREAM-INF'); depth++) {
      final variant = _pickVariant(text, playlistUrl);
      if (variant == null) break;
      if (variant.missingAudioGroup) {
        throw _DownloadError(
          '主播放列表引用的独立音轨组「${variant.audioGroupId ?? ''}」缺失，无法保存完整音画',
        );
      }
      if (variant.audioUri != null && variant.audioUri!.isNotEmpty) {
        selectedAudioUri = variant.audioUri;
        selectedAudioName = variant.audioName;
        selectedAudioLanguage = variant.audioLanguage;
      }
      if (variant.bandwidth > 0) {
        selectedBandwidth = variant.bandwidth;
      }
      playlistUrl = variant.videoUri;
      text = await _getText(playlistUrl, headers, t);
      playlistUrl = t._redirectedUrls[playlistUrl] ?? playlistUrl;
    }
    if (!text.trimLeft().replaceFirst('\uFEFF', '').startsWith('#EXTM3U')) {
      throw const _DownloadError('不是有效的 m3u8 播放列表');
    }
    final playlist = _parseMediaPlaylist(text, playlistUrl);
    if (playlist.segments.isEmpty) {
      throw const _DownloadError('播放列表中没有视频分片');
    }
    for (final s in playlist.segments) {
      final method = s.keyMethod;
      if (method != null && method != 'NONE' && method != 'AES-128') {
        throw const _DownloadError('该视频使用 SAMPLE-AES 等专有加密，暂不支持下载');
      }
    }
    final videoPlaylistHash = sha256.convert(utf8.encode(text)).toString();
    if (selectedAudioUri != null && selectedAudioUri.isNotEmpty) {
      await _downloadSeparateAudioHls(
        t: t,
        videoPlaylist: playlist,
        videoPlaylistUrl: playlistUrl,
        videoPlaylistHash: videoPlaylistHash,
        audioPlaylistUrl: selectedAudioUri,
        audioName: selectedAudioName,
        audioLanguage: selectedAudioLanguage,
        bandwidth: selectedBandwidth,
        headers: headers,
        baseName: baseName,
      );
      return;
    }
    final ext = playlist.mapUri != null ? '.mp4' : '.ts';
    final finalFile = File('$baseName$ext');
    final segDir = Directory('$baseName.segments');
    await segDir.create(recursive: true);
    final total = playlist.segments.length;
    final segFiles = List<File>.generate(
      total,
      (i) => File(_join(segDir.path, '${i.toString().padLeft(6, '0')}.seg')),
    );
    final workItems = List<_HlsDownloadWorkItem>.generate(total, (i) {
      final seg = playlist.segments[i];
      return _HlsDownloadWorkItem(
        uri: seg.uri,
        byteRange: seg.byteRange,
        keyMethod: seg.keyMethod,
        keyUri: seg.keyUri,
        iv: seg.iv,
        sequence: seg.sequence,
        stageFile: segFiles[i],
        isAudio: false,
        trackName: 'muxed',
        playlistUrl: playlistUrl,
        playlistHash: videoPlaylistHash,
        mapIdentity: seg.map?.identity ?? '',
        hasMap: playlist.hasMap,
      );
    });
    final manifest = await _HlsStageManifest.load(segDir);
    await manifest.pruneStale(
      segDir,
      workItems,
      requirePositiveMedia: false,
    );
    var done = 0;
    var bytes = 0;
    for (final item in workItems) {
      if (manifest.isReusableSync(item, requirePositiveMedia: false)) {
        done++;
        bytes += await item.stageFile.length();
      }
    }
    t.receivedBytes = bytes;
    t.progress = done / total * 0.98;
    notifyListeners();

    final keyCache = <String, Uint8List>{};
    var next = 0;
    Object? failure;
    Future<void> worker() async {
      while (failure == null) {
        if (_shouldStop(t)) throw const _StopSignal();
        final i = next++;
        if (i >= total) return;
        final item = workItems[i];
        if (manifest.isReusableSync(item, requirePositiveMedia: false)) {
          continue;
        }
        final seg = playlist.segments[i];
        try {
          final fetched = await _getBytesRetryWithMeta(
            seg.uri,
            headers,
            t,
            byteRange: seg.byteRange,
          );
          var data = fetched.bytes;
          if (seg.keyMethod == 'AES-128' && seg.keyUri != null) {
            final keyUri = seg.keyUri!;
            var key = keyCache[keyUri];
            if (key == null) {
              key = await _getBytesRetry(keyUri, headers, t);
              keyCache[keyUri] = key;
            }
            if (key.length != 16) {
              throw const _DownloadError('解密密钥格式异常');
            }
            data = await _decryptAes128(
                key, data, seg.iv ?? _ivFromSequence(seg.sequence));
          }
          _validateMediaPayload(
            data,
            contentType: fetched.contentType,
            isAudio: false,
            isMap: false,
            hasMap: playlist.hasMap,
            requirePositiveMedia: false,
          );
          final tmp = File('${item.stageFile.path}.tmp');
          await tmp.writeAsBytes(data);
          await tmp.rename(item.stageFile.path);
          await manifest.record(item, data.length);
          done++;
          bytes += data.length;
          t.receivedBytes = bytes;
          t.progress = (done / total * 0.98).clamp(0.0, 0.98);
          t.totalBytes = (bytes / done * total).round();
          _onProgress(t);
        } on _StopSignal {
          rethrow;
        } catch (e) {
          failure ??= e;
          return;
        }
      }
    }

    try {
      await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
    } finally {
      await manifest.flush();
    }
    if (_shouldStop(t)) throw const _StopSignal();
    if (failure != null) throw failure!;

    final out = File('$baseName$ext.part');
    final sink = out.openWrite();
    try {
      final firstMap = playlist.firstMap;
      if (firstMap != null) {
        final mapFetched = await _getBytesRetryWithMeta(
          firstMap.uri,
          headers,
          t,
          byteRange: firstMap.byteRange,
        );
        _validateMediaPayload(
          mapFetched.bytes,
          contentType: mapFetched.contentType,
          isAudio: false,
          isMap: true,
          hasMap: true,
          requirePositiveMedia: true,
        );
        sink.add(mapFetched.bytes);
      } else if (playlist.mapUri != null) {
        final mapFetched = await _getBytesRetryWithMeta(
          playlist.mapUri!,
          headers,
          t,
        );
        _validateMediaPayload(
          mapFetched.bytes,
          contentType: mapFetched.contentType,
          isAudio: false,
          isMap: true,
          hasMap: true,
          requirePositiveMedia: true,
        );
        sink.add(mapFetched.bytes);
      }
      for (final f in segFiles) {
        if (_shouldStop(t)) throw const _StopSignal();
        await sink.addStream(f.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await finalFile.exists()) await finalFile.delete();
    await out.rename(finalFile.path);
    try {
      await segDir.delete(recursive: true);
    } catch (_) {}
    t.filePath = finalFile.path;
    t.totalBytes = await finalFile.length();
    t.receivedBytes = t.totalBytes;
  }

  Future<void> _downloadSeparateAudioHls({
    required DownloadTask t,
    required _HlsPlaylist videoPlaylist,
    required String videoPlaylistUrl,
    required String videoPlaylistHash,
    required String audioPlaylistUrl,
    required String audioName,
    required String audioLanguage,
    required int bandwidth,
    required Map<String, String> headers,
    required String baseName,
  }) async {
    var resolvedAudioUrl = audioPlaylistUrl;
    String audioText;
    try {
      audioText = await _getText(resolvedAudioUrl, headers, t);
      resolvedAudioUrl = t._redirectedUrls[resolvedAudioUrl] ?? resolvedAudioUrl;
    } on _StopSignal {
      rethrow;
    } catch (e) {
      throw _DownloadError('独立音轨播放列表获取失败，无法保存完整音画：${_friendlyError(e)}');
    }
    if (!audioText.trimLeft().replaceFirst('\uFEFF', '').startsWith('#EXTM3U')) {
      throw const _DownloadError('独立音轨播放列表格式无效，无法保存完整音画');
    }
    final audioPlaylist = _parseMediaPlaylist(audioText, resolvedAudioUrl);
    if (audioPlaylist.segments.isEmpty) {
      throw const _DownloadError('独立音轨播放列表中没有音频分片，无法保存完整音画');
    }
    for (final s in audioPlaylist.segments) {
      final method = s.keyMethod;
      if (method != null && method != 'NONE' && method != 'AES-128') {
        throw const _DownloadError('独立音轨使用 SAMPLE-AES 等专有加密，暂不支持下载');
      }
    }
    final audioPlaylistHash = sha256.convert(utf8.encode(audioText)).toString();

    final stageDir = Directory('$baseName.hls.part');
    await stageDir.create(recursive: true);

    final workItems = <_HlsDownloadWorkItem>[];
    final videoMapFiles = <String, ({String name, File stageFile})>{};
    final audioMapFiles = <String, ({String name, File stageFile})>{};

    void registerMaps(
      _HlsPlaylist pl,
      bool isAudio,
      String playlistUrl,
      String playlistHash,
    ) {
      final mapTable = isAudio ? audioMapFiles : videoMapFiles;
      final prefix = isAudio ? 'a_map' : 'v_map';
      for (final seg in pl.segments) {
        final map = seg.map;
        if (map == null || mapTable.containsKey(map.identity)) continue;
        final idx = mapTable.length;
        final name = '${prefix}_$idx.mp4';
        final stageFile = File(_join(stageDir.path, name));
        mapTable[map.identity] = (name: name, stageFile: stageFile);
        workItems.add(
          _HlsDownloadWorkItem(
            uri: map.uri,
            byteRange: map.byteRange,
            stageFile: stageFile,
            isAudio: isAudio,
            isMap: true,
            trackName: isAudio ? 'audio' : 'video',
            playlistUrl: playlistUrl,
            playlistHash: playlistHash,
            mapIdentity: map.identity,
            hasMap: true,
          ),
        );
      }
    }

    registerMaps(videoPlaylist, false, videoPlaylistUrl, videoPlaylistHash);
    registerMaps(audioPlaylist, true, resolvedAudioUrl, audioPlaylistHash);

    final videoStageFiles = List<File>.generate(
      videoPlaylist.segments.length,
      (i) => File(_join(stageDir.path, 'v_${i.toString().padLeft(6, '0')}.seg')),
    );
    final audioStageFiles = List<File>.generate(
      audioPlaylist.segments.length,
      (i) => File(_join(stageDir.path, 'a_${i.toString().padLeft(6, '0')}.seg')),
    );
    for (var i = 0; i < videoPlaylist.segments.length; i++) {
      final seg = videoPlaylist.segments[i];
      workItems.add(
        _HlsDownloadWorkItem(
          uri: seg.uri,
          byteRange: seg.byteRange,
          keyMethod: seg.keyMethod,
          keyUri: seg.keyUri,
          iv: seg.iv,
          sequence: seg.sequence,
          stageFile: videoStageFiles[i],
          isAudio: false,
          trackName: 'video',
          playlistUrl: videoPlaylistUrl,
          playlistHash: videoPlaylistHash,
          mapIdentity: seg.map?.identity ?? '',
          hasMap: videoPlaylist.hasMap,
        ),
      );
    }
    for (var i = 0; i < audioPlaylist.segments.length; i++) {
      final seg = audioPlaylist.segments[i];
      workItems.add(
        _HlsDownloadWorkItem(
          uri: seg.uri,
          byteRange: seg.byteRange,
          keyMethod: seg.keyMethod,
          keyUri: seg.keyUri,
          iv: seg.iv,
          sequence: seg.sequence,
          stageFile: audioStageFiles[i],
          isAudio: true,
          trackName: 'audio',
          playlistUrl: resolvedAudioUrl,
          playlistHash: audioPlaylistHash,
          mapIdentity: seg.map?.identity ?? '',
          hasMap: audioPlaylist.hasMap,
        ),
      );
    }

    final manifest = await _HlsStageManifest.load(stageDir);
    await manifest.pruneStale(
      stageDir,
      workItems,
      requirePositiveMedia: true,
    );

    final total = workItems.length;
    var done = 0;
    var bytes = 0;
    for (final item in workItems) {
      if (manifest.isReusableSync(item, requirePositiveMedia: true)) {
        done++;
        bytes += await item.stageFile.length();
      }
    }
    t.receivedBytes = bytes;
    t.progress = (done / total * 0.96).clamp(0.0, 0.96);
    notifyListeners();

    final keyCache = <String, Uint8List>{};
    var next = 0;
    Object? failure;
    var audioFailed = false;
    Future<void> worker() async {
      while (failure == null) {
        if (_shouldStop(t)) throw const _StopSignal();
        final idx = next++;
        if (idx >= total) return;
        final item = workItems[idx];
        if (manifest.isReusableSync(item, requirePositiveMedia: true)) {
          continue;
        }
        try {
          final fetched = await _getBytesRetryWithMeta(
            item.uri,
            headers,
            t,
            byteRange: item.byteRange,
          );
          var data = fetched.bytes;
          if (item.keyMethod == 'AES-128' && item.keyUri != null) {
            final keyUri = item.keyUri!;
            var key = keyCache[keyUri];
            if (key == null) {
              key = await _getBytesRetry(keyUri, headers, t);
              keyCache[keyUri] = key;
            }
            if (key.length != 16) {
              throw const _DownloadError('解密密钥格式异常');
            }
            data = await _decryptAes128(
                key, data, item.iv ?? _ivFromSequence(item.sequence));
          }
          _validateMediaPayload(
            data,
            contentType: fetched.contentType,
            isAudio: item.isAudio,
            isMap: item.isMap,
            hasMap: item.hasMap,
            requirePositiveMedia: true,
          );
          final tmp = File('${item.stageFile.path}.tmp');
          await tmp.writeAsBytes(data);
          await tmp.rename(item.stageFile.path);
          await manifest.record(item, data.length);
          done++;
          bytes += data.length;
          t.receivedBytes = bytes;
          t.progress = (done / total * 0.96).clamp(0.0, 0.96);
          t.totalBytes = (bytes / done * total).round();
          _onProgress(t);
        } on _StopSignal {
          rethrow;
        } catch (e) {
          if (failure == null) {
            failure = e;
            audioFailed = item.isAudio;
          }
          return;
        }
      }
    }

    try {
      await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
    } finally {
      await manifest.flush();
    }
    if (_shouldStop(t)) throw const _StopSignal();
    if (failure != null) {
      if (audioFailed) {
        if (failure is _DownloadError) {
          final msg = (failure! as _DownloadError).message;
          if (!msg.contains('独立音轨')) {
            throw _DownloadError('独立音轨：$msg');
          }
          throw failure!;
        }
        throw _DownloadError('独立音轨分片下载失败，无法保存完整音画：${_friendlyError(failure!)}');
      }
      throw failure!;
    }

    final taskDir = File(baseName).parent;
    final bundleDir = Directory(_join(taskDir.path, 'hls'));
    final stagingBundleDir = Directory(_join(taskDir.path, 'hls.assembling'));
    if (await stagingBundleDir.exists()) {
      await stagingBundleDir.delete(recursive: true);
    }
    await stagingBundleDir.create(recursive: true);

    var bundleTotalBytes = 0;

    Future<String> assembleMediaPlaylist({
      required _HlsPlaylist playlist,
      required List<File> stageFiles,
      required Map<String, ({String name, File stageFile})> mapFiles,
      required String prefix,
      required String playlistFileName,
      required bool isAudio,
    }) async {
      for (final entry in mapFiles.values) {
        final dst = File(_join(stagingBundleDir.path, entry.name));
        await entry.stageFile.copy(dst.path);
        bundleTotalBytes += await dst.length();
      }
      final buf = StringBuffer()
        ..writeln('#EXTM3U')
        ..writeln('#EXT-X-VERSION:${playlist.hasMap ? 7 : 3}')
        ..writeln('#EXT-X-TARGETDURATION:${math.max(1, playlist.targetDuration)}')
        ..writeln('#EXT-X-MEDIA-SEQUENCE:0')
        ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');

      String? activeMapIdentity;
      for (var i = 0; i < playlist.segments.length; i++) {
        if (_shouldStop(t)) throw const _StopSignal();
        final seg = playlist.segments[i];
        final stageFile = stageFiles[i];
        final head = await _readHeadBytes(stageFile, 256);
        final ext = _sniffMediaExtension(
          head,
          url: seg.uri,
          hasMap: playlist.hasMap,
          isAudio: isAudio,
        );
        final outName = '${prefix}_${i.toString().padLeft(6, '0')}$ext';
        final dst = File(_join(stagingBundleDir.path, outName));
        await stageFile.copy(dst.path);
        bundleTotalBytes += await dst.length();

        if (seg.discontinuity) {
          buf.writeln('#EXT-X-DISCONTINUITY');
        }
        final map = seg.map;
        if (map != null && map.identity != activeMapIdentity) {
          final mapEntry = mapFiles[map.identity];
          if (mapEntry != null) {
            buf.writeln('#EXT-X-MAP:URI="${mapEntry.name}"');
            activeMapIdentity = map.identity;
          }
        }
        final dur = seg.duration > 0 ? seg.duration : 4.0;
        buf.writeln('#EXTINF:${dur.toStringAsFixed(3)},');
        buf.writeln(outName);
      }
      buf.writeln('#EXT-X-ENDLIST');
      final outPlaylist = File(_join(stagingBundleDir.path, playlistFileName));
      await outPlaylist.writeAsString(buf.toString());
      bundleTotalBytes += await outPlaylist.length();
      return playlistFileName;
    }

    try {
      await assembleMediaPlaylist(
        playlist: videoPlaylist,
        stageFiles: videoStageFiles,
        mapFiles: videoMapFiles,
        prefix: 'v',
        playlistFileName: 'video.m3u8',
        isAudio: false,
      );
      await assembleMediaPlaylist(
        playlist: audioPlaylist,
        stageFiles: audioStageFiles,
        mapFiles: audioMapFiles,
        prefix: 'a',
        playlistFileName: 'audio.m3u8',
        isAudio: true,
      );

      final versionTag =
          (videoPlaylist.hasMap || audioPlaylist.hasMap) ? 7 : 3;
      final safeAudioName = audioName.replaceAll('"', '').trim();
      final displayAudioName =
          safeAudioName.isEmpty ? 'Default' : safeAudioName;
      final safeLang = audioLanguage.replaceAll('"', '').trim();
      final langAttr = safeLang.isNotEmpty ? ',LANGUAGE="$safeLang"' : '';
      final effectiveBw = bandwidth > 0 ? bandwidth : 2000000;
      final masterContent = StringBuffer()
        ..writeln('#EXTM3U')
        ..writeln('#EXT-X-VERSION:$versionTag')
        ..writeln('#EXT-X-INDEPENDENT-SEGMENTS')
        ..writeln(
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="$displayAudioName"$langAttr,DEFAULT=YES,AUTOSELECT=YES,URI="hls/audio.m3u8"',
        )
        ..writeln('#EXT-X-STREAM-INF:BANDWIDTH=$effectiveBw,AUDIO="audio"')
        ..writeln('hls/video.m3u8');

      final masterFile = File('$baseName.m3u8');
      final masterPart = File('$baseName.m3u8.part');
      await masterPart.writeAsString(masterContent.toString());
      bundleTotalBytes += await masterPart.length();

      if (await bundleDir.exists()) {
        await bundleDir.delete(recursive: true);
      }
      await stagingBundleDir.rename(bundleDir.path);
      if (await masterFile.exists()) {
        await masterFile.delete();
      }
      await masterPart.rename(masterFile.path);
      t.filePath = masterFile.path;
      if (!_verifyCompletedFilesExist(t)) {
        t.filePath = '';
        throw const _DownloadError('离线音视频分片校验未通过，无法完成下载');
      }
      try {
        await stageDir.delete(recursive: true);
      } catch (_) {}

      t.totalBytes = bundleTotalBytes;
      t.receivedBytes = bundleTotalBytes;
    } catch (_) {
      try {
        if (await stagingBundleDir.exists()) {
          await stagingBundleDir.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  static Future<Uint8List> _readHeadBytes(File file, int maxBytes) async {
    final raf = await file.open();
    try {
      return await raf.read(maxBytes);
    } finally {
      await raf.close();
    }
  }

  static Uint8List _readHeadBytesSync(File file, int maxBytes) {
    final raf = file.openSync();
    try {
      return raf.readSync(maxBytes);
    } finally {
      raf.closeSync();
    }
  }

  static String _trackLabel({required bool isAudio, required bool isMap}) {
    if (isAudio) return isMap ? '独立音轨初始化段' : '独立音轨分片';
    return isMap ? '视频初始化段' : '视频分片';
  }

  static void _validateMediaPayload(
    Uint8List data, {
    required String contentType,
    required bool isAudio,
    required bool isMap,
    required bool hasMap,
    required bool requirePositiveMedia,
  }) {
    final label = _trackLabel(isAudio: isAudio, isMap: isMap);
    final suffix = isAudio ? '，无法保存完整音画' : '';
    if (data.isEmpty) {
      throw _DownloadError('$label为空$suffix');
    }
    final mime = contentType.toLowerCase().trim();
    if (mime == 'text/html' ||
        mime == 'application/xhtml+xml' ||
        mime == 'text/xml' ||
        mime == 'application/xml' ||
        mime == 'application/json') {
      throw _DownloadError('$label返回网页或错误内容（$mime）$suffix');
    }

    var start = 0;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      start = 3;
    }
    while (start < data.length &&
        (data[start] == 0x20 ||
            data[start] == 0x09 ||
            data[start] == 0x0A ||
            data[start] == 0x0D)) {
      start++;
    }
    if (start < data.length) {
      final probeEnd = math.min(data.length, start + 512);
      final headText = utf8
          .decode(Uint8List.sublistView(data, start, probeEnd),
              allowMalformed: true)
          .toLowerCase();
      for (final prefix in const [
        '<!doctype',
        '<html',
        '<head',
        '<body',
        '<title',
        '<script',
        '<div',
        '<h1',
        '<center',
        '<?xml',
        '<error',
        '<message',
        '<response',
        '#extm3u',
      ]) {
        if (headText.startsWith(prefix)) {
          throw _DownloadError('$label返回非媒体错误页面，无法解析$suffix');
        }
      }
      if (headText.startsWith('{') &&
          (headText.contains('"error"') ||
              headText.contains('"message"') ||
              headText.contains('"msg"') ||
              headText.contains('"code"') ||
              headText.contains('"status"'))) {
        throw _DownloadError('$label返回错误响应（JSON）$suffix');
      }
    }

    final mustMatchMedia = requirePositiveMedia || mime == 'text/plain';
    if (mustMatchMedia &&
        !_hasRecognizedMediaSignature(
          data,
          isAudio: isAudio,
          isMap: isMap,
          hasMap: hasMap,
        )) {
      throw _DownloadError('$label内容不是有效的音视频媒体数据$suffix');
    }
  }

  static bool _isIsoBmffBox(Uint8List data, int offset) {
    if (offset + 8 > data.length) return false;
    final size = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    if (size != 0 && size != 1 && size < 8) return false;
    final box = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    return const {
      'ftyp',
      'styp',
      'moof',
      'moov',
      'sidx',
      'mdat',
      'emsg',
      'prft',
      'free',
      'skip',
      'pdin',
      'meta',
      'uuid',
    }.contains(box);
  }

  static bool _hasRecognizedMediaSignature(
    Uint8List data, {
    required bool isAudio,
    required bool isMap,
    required bool hasMap,
  }) {
    if (data.length < 4) return false;
    if (isMap) {
      return _isIsoBmffBox(data, 0);
    }
    if (_isIsoBmffBox(data, 0)) return true;

    // MPEG-TS (direct or after a small disguised image header)
    if (data[0] == 0x47 && (data.length < 189 || data[188] == 0x47)) {
      return true;
    }
    if (data.length >= 192) {
      final limit = math.min(data.length - 189, 256);
      for (var i = 1; i <= limit; i++) {
        if (data[i] == 0x47 && data[i + 188] == 0x47) {
          return true;
        }
      }
    }

    // ID3v2 wrapped audio (HLS elementary AAC / MP3 / AC-3 / TS)
    var offset = 0;
    if (data.length >= 10 &&
        data[0] == 0x49 &&
        data[1] == 0x44 &&
        data[2] == 0x33 &&
        (data[6] & 0x80) == 0 &&
        (data[7] & 0x80) == 0 &&
        (data[8] & 0x80) == 0 &&
        (data[9] & 0x80) == 0) {
      final id3Size = ((data[6] & 0x7F) << 21) |
          ((data[7] & 0x7F) << 14) |
          ((data[8] & 0x7F) << 7) |
          (data[9] & 0x7F);
      offset = 10 + id3Size;
      if (offset >= data.length) {
        // Large ID3 header exceeding head probe window; treat as valid ID3 audio.
        return isAudio || id3Size > 0;
      }
    }

    if (offset + 4 <= data.length) {
      final b0 = data[offset];
      final b1 = data[offset + 1];
      final b2 = data[offset + 2];
      final b3 = data[offset + 3];
      if (b0 == 0x47 &&
          (offset + 188 >= data.length || data[offset + 188] == 0x47)) {
        return true;
      }
      // ADTS AAC syncword (12 bits of 1s + layer == 00)
      if (b0 == 0xFF && (b1 & 0xF6) == 0xF0) return true;
      // MPEG audio (MP3/MP2)
      if (b0 == 0xFF && (b1 & 0xE0) == 0xE0 && (b1 & 0x06) != 0) return true;
      // AC-3 / E-AC-3
      if (b0 == 0x0B && b1 == 0x77) return true;
      // FLAC ("fLaC")
      if (b0 == 0x66 && b1 == 0x4C && b2 == 0x61 && b3 == 0x43) return true;
      // Ogg ("OggS")
      if (b0 == 0x4F && b1 == 0x67 && b2 == 0x67 && b3 == 0x53) return true;
      // WebM / Matroska EBML
      if (b0 == 0x1A && b1 == 0x45 && b2 == 0xDF && b3 == 0xA3) return true;
      // RIFF / WAV
      if (b0 == 0x52 && b1 == 0x49 && b2 == 0x46 && b3 == 0x46) return true;
    }

    // H.264 / H.265 Annex-B NAL start code (rare raw elementary video)
    if (!isAudio &&
        data[0] == 0x00 &&
        data[1] == 0x00 &&
        ((data[2] == 0x00 && data[3] == 0x01) || data[2] == 0x01)) {
      return true;
    }

    return false;
  }

  static String _sniffMediaExtension(
    Uint8List head, {
    required String url,
    required bool hasMap,
    required bool isAudio,
  }) {
    if (head.length >= 8) {
      final box = String.fromCharCodes(head.sublist(4, 8));
      if (box == 'ftyp' ||
          box == 'styp' ||
          box == 'moof' ||
          box == 'moov' ||
          box == 'sidx' ||
          box == 'mdat') {
        return hasMap ? '.m4s' : (isAudio ? '.m4a' : '.mp4');
      }
    }
    if (head.isNotEmpty && head[0] == 0x47) {
      if (head.length < 189 || head[188] == 0x47) {
        return '.ts';
      }
    }
    // Check ADTS AAC (raw or after ID3v2 tag).
    var offset = 0;
    if (head.length >= 10 &&
        head[0] == 0x49 &&
        head[1] == 0x44 &&
        head[2] == 0x33) {
      final id3Size = ((head[6] & 0x7F) << 21) |
          ((head[7] & 0x7F) << 14) |
          ((head[8] & 0x7F) << 7) |
          (head[9] & 0x7F);
      offset = 10 + id3Size;
      if (offset >= head.length && isAudio) {
        final lowerPath = url.toLowerCase().split('?').first.split('#').first;
        if (lowerPath.endsWith('.mp3')) return '.mp3';
        if (lowerPath.endsWith('.ac3')) return '.ac3';
        if (lowerPath.endsWith('.ec3')) return '.ec3';
        return '.aac';
      }
    }
    if (offset + 2 <= head.length) {
      final b0 = head[offset];
      final b1 = head[offset + 1];
      if (b0 == 0x47) return '.ts';
      if (b0 == 0xFF && (b1 & 0xF6) == 0xF0) return '.aac';
      if (b0 == 0xFF && (b1 & 0xE0) == 0xE0) return '.mp3';
      if (b0 == 0x0B && b1 == 0x77) return '.ac3';
    }
    if (hasMap) return '.m4s';
    final path = url.toLowerCase().split('?').first.split('#').first;
    for (final ext in const [
      '.ts',
      '.m4s',
      '.mp4',
      '.m4a',
      '.aac',
      '.mp3',
      '.ac3',
      '.ec3',
    ]) {
      if (path.endsWith(ext)) return ext;
    }
    return '.ts';
  }

  _HlsSelectedVariant? _pickVariant(String text, String baseUrl) {
    final base = Uri.parse(baseUrl);
    final lines = const LineSplitter().convert(text);
    final audioGroups = <String, List<_HlsAudioRendition>>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-MEDIA:')) continue;
      final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
      if ((attrs['TYPE'] ?? '').toUpperCase() != 'AUDIO') continue;
      final groupId = attrs['GROUP-ID'] ?? '';
      if (groupId.isEmpty) continue;
      final rawUri = attrs['URI'];
      final resolvedUri = (rawUri != null && rawUri.isNotEmpty)
          ? base.resolve(rawUri).toString()
          : null;
      audioGroups.putIfAbsent(groupId, () => []).add(
            _HlsAudioRendition(
              groupId: groupId,
              name: attrs['NAME'] ?? '默认音轨',
              language: attrs['LANGUAGE'] ?? '',
              uri: resolvedUri,
              isDefault: (attrs['DEFAULT'] ?? '').toUpperCase() == 'YES',
              autoselect: (attrs['AUTOSELECT'] ?? '').toUpperCase() == 'YES',
            ),
          );
    }

    _HlsSelectedVariant? best;
    var bestBandwidth = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
      final bandwidth = int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
      final audioGroupId = attrs['AUDIO'];
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        final videoUri = base.resolve(candidate).toString();
        String? audioUri;
        var audioName = '默认音轨';
        var audioLang = '';
        var missingGroup = false;
        if (audioGroupId != null && audioGroupId.isNotEmpty) {
          final group = audioGroups[audioGroupId];
          if (group == null || group.isEmpty) {
            missingGroup = true;
          } else {
            final chosen = _chooseAudioRendition(group);
            audioUri = chosen.uri;
            audioName = chosen.name;
            audioLang = chosen.language;
          }
        }
        final shouldReplace = best == null ||
            (best.missingAudioGroup && !missingGroup) ||
            (best.missingAudioGroup == missingGroup &&
                bandwidth > bestBandwidth);
        if (shouldReplace) {
          bestBandwidth = bandwidth;
          best = _HlsSelectedVariant(
            videoUri: videoUri,
            bandwidth: bandwidth,
            audioGroupId: audioGroupId,
            audioUri: audioUri,
            audioName: audioName,
            audioLanguage: audioLang,
            missingAudioGroup: missingGroup,
          );
        }
        break;
      }
    }
    return best;
  }

  static _HlsAudioRendition _chooseAudioRendition(
    List<_HlsAudioRendition> group,
  ) {
    for (final r in group) {
      if (r.isDefault && r.uri != null) return r;
    }
    for (final r in group) {
      if (r.isDefault) return r;
    }
    for (final r in group) {
      if (r.autoselect && r.uri != null) return r;
    }
    for (final r in group) {
      if (r.autoselect) return r;
    }
    return group.first;
  }

  static _HlsByteRange? _parseByteRange(String raw, int? previousEnd) {
    final parts = raw.trim().split('@');
    final length = int.tryParse(parts[0].trim());
    if (length == null || length <= 0) return null;
    final offset = parts.length >= 2
        ? int.tryParse(parts[1].trim())
        : previousEnd;
    if (offset == null || offset < 0) return null;
    return _HlsByteRange(length: length, offset: offset);
  }

  _HlsPlaylist _parseMediaPlaylist(String text, String baseUrl) {
    final base = Uri.parse(baseUrl);
    var sequence = 0;
    var targetDuration = 0;
    var maxDuration = 0.0;
    double? pendingDuration;
    var pendingDiscontinuity = false;
    _HlsByteRange? pendingByteRange;
    int? lastByteRangeEnd;
    String? method;
    String? keyUri;
    Uint8List? iv;
    String? firstMapUri;
    _HlsMapInfo? firstMap;
    _HlsMapInfo? activeMap;
    final segments = <_HlsSegment>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        sequence = int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
        continue;
      }
      if (line.startsWith('#EXT-X-TARGETDURATION')) {
        targetDuration =
            int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ?? 0;
        continue;
      }
      if (line.startsWith('#EXTINF:')) {
        final rawDur = line.substring('#EXTINF:'.length).split(',').first.trim();
        final parsed = double.tryParse(rawDur);
        if (parsed != null && parsed > 0) {
          pendingDuration = parsed;
          if (parsed > maxDuration) maxDuration = parsed;
        }
        continue;
      }
      if (line == '#EXT-X-DISCONTINUITY') {
        pendingDiscontinuity = true;
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingByteRange = _parseByteRange(
          line.substring('#EXT-X-BYTERANGE:'.length),
          lastByteRangeEnd,
        );
        if (pendingByteRange != null) {
          lastByteRangeEnd = pendingByteRange.offset + pendingByteRange.length;
        }
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
        method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
        final uri = attrs['URI'];
        keyUri = (uri != null && uri.isNotEmpty) ? base.resolve(uri).toString() : null;
        final ivHex = attrs['IV'];
        iv = (ivHex != null && ivHex.isNotEmpty) ? _parseIv(ivHex) : null;
        if (method == 'NONE') {
          keyUri = null;
          iv = null;
        }
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
        final uri = attrs['URI'];
        if (uri != null && uri.isNotEmpty) {
          final resolved = base.resolve(uri).toString();
          final brAttr = attrs['BYTERANGE'];
          final mapRange = (brAttr != null && brAttr.isNotEmpty)
              ? _parseByteRange(brAttr, 0)
              : null;
          activeMap = _HlsMapInfo(uri: resolved, byteRange: mapRange);
          if (firstMapUri == null) {
            firstMapUri = resolved;
            firstMap = activeMap;
          }
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      segments.add(
        _HlsSegment(
          uri: base.resolve(line).toString(),
          keyMethod: method,
          keyUri: keyUri,
          iv: iv,
          sequence: sequence,
          duration: pendingDuration ?? 4.0,
          discontinuity: pendingDiscontinuity,
          byteRange: pendingByteRange,
          map: activeMap,
        ),
      );
      pendingDuration = null;
      pendingDiscontinuity = false;
      pendingByteRange = null;
      sequence++;
    }
    final resolvedTarget = targetDuration > 0
        ? targetDuration
        : math.max(1, maxDuration.ceil());
    return _HlsPlaylist(
      segments,
      firstMapUri,
      firstMap: firstMap,
      targetDuration: resolvedTarget,
    );
  }

  static Map<String, String> _parseAttributes(String input) {
    final out = <String, String>{};
    final pattern = RegExp(r'([A-Za-z0-9-]+)=("[^"]*"|[^,]*)');
    for (final m in pattern.allMatches(input)) {
      var value = m.group(2) ?? '';
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      out[m.group(1)!.toUpperCase()] = value.trim();
    }
    return out;
  }

  static Uint8List _parseIv(String hex) {
    var h = hex.trim();
    if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
    if (h.length > 32) h = h.substring(h.length - 32);
    h = h.padLeft(32, '0');
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16) ?? 0;
    }
    return out;
  }

  static Uint8List _ivFromSequence(int sequence) {
    final iv = Uint8List(16);
    var value = sequence;
    for (var i = 15; i >= 8 && value > 0; i--) {
      iv[i] = value & 0xFF;
      value = value >> 8;
    }
    return iv;
  }

  /// Pure-Dart AES-128-CBC is CPU heavy (~1 MB segment ≈ tens of ms on a
  /// phone). Running it on the UI isolate stalled both frames and the socket
  /// event loop of the other segment workers, so big segments are decrypted on
  /// a short-lived background isolate (result is transferred, not copied).
  static Future<Uint8List> _decryptAes128(
    Uint8List key,
    Uint8List data,
    Uint8List iv,
  ) async {
    if (!kIsWeb && data.length >= _isolateDecryptThreshold) {
      try {
        return await Isolate.run<Uint8List>(
          () => _decryptAes128Sync(key, data, iv),
          debugName: 'marco-hls-aes',
        );
      } catch (_) {
        // Fall back to the current isolate (e.g. isolates unavailable).
      }
    }
    return _decryptAes128Sync(key, data, iv);
  }

  static Uint8List _decryptAes128Sync(
    Uint8List key,
    Uint8List data,
    Uint8List iv,
  ) =>
      _Aes128Cbc(key).decrypt(data, iv);

  // ---------------------------------------------------------------------------
  // HTTP helpers
  // ---------------------------------------------------------------------------

  @visibleForTesting
  static Map<String, String> headersForOrigin(Map<String, String> headers,
      Uri? origin, Uri? target) {
    return SourcePlayback.headersForOrigin(headers, origin, target);
  }

  Future<HttpClientResponse> _open(String url, Map<String, String> headers,
      DownloadTask task, {String? range}) async {
    var target = Uri.parse(url);
    if (task._credentialOrigin?.scheme == 'https' && target.scheme != 'https') {
      throw const _DownloadError('拒绝将安全下载降级为 HTTP');
    }
    var currentHeaders = headersForOrigin(headers, task._credentialOrigin, target);
    for (var hop = 0; hop <= 8; hop++) {
      if (_shouldStop(task)) throw const _StopSignal();
      if (!const {'http', 'https'}.contains(target.scheme)) {
        throw const _DownloadError('不支持的下载地址');
      }
      final request = await _http.getUrl(target);
      request.followRedirects = false;
      _applyHeaders(request, currentHeaders);
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        task._redirectedUrls[url] = target.toString();
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) throw const _DownloadError('重定向缺少目标地址');
      final next = target.resolve(location);
      if (target.scheme == 'https' && next.scheme != 'https') {
        throw const _DownloadError('拒绝将安全下载降级为 HTTP');
      }
      currentHeaders = headersForOrigin(currentHeaders, target, next);
      target = next;
    }
    throw const _DownloadError('下载重定向次数过多');
  }

  void _applyHeaders(HttpClientRequest request, Map<String, String> headers) {
    var hasUa = false;
    headers.forEach((k, v) {
      final lower = k.toLowerCase();
      if (lower == 'host' || lower == 'content-length' || lower == 'range') return;
      if (lower == 'user-agent') hasUa = true;
      try {
        request.headers.set(k, v);
      } catch (_) {}
    });
    if (!hasUa) request.headers.set(HttpHeaders.userAgentHeader, _defaultUa);
  }

  Future<_FetchedBytes> _getBytesOnceWithMeta(
    String url,
    Map<String, String> headers,
    DownloadTask t, {
    _HlsByteRange? byteRange,
  }) async {
    final response = await _open(
      url,
      headers,
      t,
      range: byteRange?.httpRangeHeader,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      final retryable = response.statusCode >= 500 || response.statusCode == 429;
      throw _DownloadError(
        '服务器返回 HTTP ${response.statusCode}',
        retryable: retryable,
      );
    }
    final contentType = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    final contentEncoding =
        (response.headers.value(HttpHeaders.contentEncodingHeader) ?? '')
            .trim()
            .toLowerCase();
    final isIdentityEncoding =
        contentEncoding.isEmpty || contentEncoding == 'identity';
    final declaredLength = response.contentLength;
    int? expectedNonRanged206Length;

    if (byteRange != null) {
      if (byteRange.offset < 0 || byteRange.length <= 0) {
        await response.drain<void>();
        throw const _DownloadError('分片字节范围参数无效');
      }
      final expectedStart = byteRange.offset;
      final expectedEnd = byteRange.offset + byteRange.length - 1;
      if (response.statusCode == 206) {
        final rawRange =
            (response.headers.value(HttpHeaders.contentRangeHeader) ?? '')
                .trim();
        final match = RegExp(
          r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
          caseSensitive: false,
        ).firstMatch(rawRange);
        if (match == null) {
          await response.drain<void>();
          throw const _DownloadError('分片 206 响应缺少有效的 Content-Range 头');
        }
        final respStart = int.tryParse(match.group(1)!);
        final respEnd = int.tryParse(match.group(2)!);
        final respTotal =
            match.group(3) == '*' ? null : int.tryParse(match.group(3)!);
        if (respStart == null ||
            respEnd == null ||
            respEnd < respStart ||
            (respTotal != null && respEnd >= respTotal)) {
          await response.drain<void>();
          throw _DownloadError('分片 206 响应的 Content-Range 非法（$rawRange）');
        }
        if (respStart != expectedStart || respEnd != expectedEnd) {
          await response.drain<void>();
          throw _DownloadError(
            '分片字节范围不匹配（请求 bytes=$expectedStart-$expectedEnd，返回 bytes $respStart-$respEnd）',
          );
        }
        if (isIdentityEncoding &&
            declaredLength >= 0 &&
            declaredLength != byteRange.length) {
          await response.drain<void>();
          throw _DownloadError(
            '分片 206 响应长度异常（期望 ${byteRange.length} 字节，声明 $declaredLength 字节）',
          );
        }
      } else if (response.statusCode != 200) {
        await response.drain<void>();
        throw _DownloadError('分片范围请求返回异常状态码 HTTP ${response.statusCode}');
      }
    } else if (response.statusCode == 206) {
      final rawRange =
          (response.headers.value(HttpHeaders.contentRangeHeader) ?? '').trim();
      final match = RegExp(
        r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
        caseSensitive: false,
      ).firstMatch(rawRange);
      final respStart = match == null ? null : int.tryParse(match.group(1)!);
      final respEnd = match == null ? null : int.tryParse(match.group(2)!);
      final respTotal = (match == null || match.group(3) == '*')
          ? null
          : int.tryParse(match.group(3)!);
      if (respStart == null ||
          respEnd == null ||
          respStart != 0 ||
          respTotal == null ||
          respTotal <= 0 ||
          respEnd != respTotal - 1) {
        await response.drain<void>();
        throw _DownloadError('分片未请求范围却返回不完整 206 响应（$rawRange）');
      }
      expectedNonRanged206Length = respTotal;
      if (isIdentityEncoding &&
          declaredLength >= 0 &&
          declaredLength != expectedNonRanged206Length) {
        await response.drain<void>();
        throw _DownloadError(
          '分片未请求范围但 206 响应长度不完整（完整范围 $expectedNonRanged206Length 字节，声明 $declaredLength 字节）',
        );
      }
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_streamIdleTimeout)) {
      if (_shouldStop(t)) throw const _StopSignal();
      builder.add(chunk);
      if (builder.length > _maxSegmentBytes) {
        throw const _DownloadError('单个分片过大');
      }
      t._wireBytes += chunk.length;
      _onProgress(t);
    }
    final bytes = builder.takeBytes();
    if (isIdentityEncoding &&
        declaredLength >= 0 &&
        bytes.length != declaredLength) {
      throw _DownloadError(
        '分片传输不完整（期望 $declaredLength 字节，实收 ${bytes.length} 字节）',
        retryable: true,
      );
    }
    if (expectedNonRanged206Length != null &&
        bytes.length != expectedNonRanged206Length) {
      throw _DownloadError(
        '分片未请求范围但 206 实收字节不完整（完整范围 $expectedNonRanged206Length 字节，实收 ${bytes.length} 字节）',
      );
    }
    if (byteRange != null) {
      if (response.statusCode == 206) {
        if (bytes.length != byteRange.length) {
          throw _DownloadError(
            '分片 206 实收字节数不完整（期望 ${byteRange.length} 字节，实收 ${bytes.length} 字节）',
          );
        }
        return _FetchedBytes(bytes, contentType);
      }
      final end = byteRange.offset + byteRange.length;
      if (byteRange.offset >= 0 && end <= bytes.length) {
        return _FetchedBytes(
          Uint8List.sublistView(bytes, byteRange.offset, end),
          contentType,
        );
      }
      throw _DownloadError(
        '分片字节范围越界（期望 ${byteRange.offset}-${end - 1}，资源长度 ${bytes.length}）',
      );
    }
    return _FetchedBytes(bytes, contentType);
  }

  Future<_FetchedBytes> _getBytesRetryWithMeta(
    String url,
    Map<String, String> headers,
    DownloadTask t, {
    _HlsByteRange? byteRange,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_shouldStop(t)) throw const _StopSignal();
      try {
        return await _getBytesOnceWithMeta(
          url,
          headers,
          t,
          byteRange: byteRange,
        );
      } on _StopSignal {
        rethrow;
      } on _DownloadError catch (e) {
        lastError = e;
        if (!e.retryable) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw lastError ?? const _DownloadError('网络请求失败');
  }

  Future<Uint8List> _getBytesRetry(
    String url,
    Map<String, String> headers,
    DownloadTask t, {
    _HlsByteRange? byteRange,
  }) async {
    final res = await _getBytesRetryWithMeta(
      url,
      headers,
      t,
      byteRange: byteRange,
    );
    return res.bytes;
  }

  Future<String> _getText(String url, Map<String, String> headers, DownloadTask t) async {
    final bytes = await _getBytesRetry(url, headers, t);
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---------------------------------------------------------------------------
  // Misc helpers
  // ---------------------------------------------------------------------------

  static bool _looksLikeHls(String url) {
    final lower = url.toLowerCase();
    final path = lower.split('?').first.split('#').first;
    return path.endsWith('.m3u8') || path.contains('.m3u8') || lower.contains('m3u8?') ||
        lower.contains('type=m3u8') || lower.contains('format=m3u8');
  }

  static bool _startsWithM3u(List<int> chunk) {
    var i = 0;
    if (chunk.length >= 3 && chunk[0] == 0xEF && chunk[1] == 0xBB && chunk[2] == 0xBF) i = 3;
    while (i < chunk.length && (chunk[i] == 0x20 || chunk[i] == 0x0A || chunk[i] == 0x0D || chunk[i] == 0x09)) {
      i++;
    }
    const sig = [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // #EXTM3U
    if (chunk.length - i < sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (chunk[i + k] != sig[k]) return false;
    }
    return true;
  }

  static String _extFromUrl(String url, {required String fallback}) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    const known = ['.mp4', '.mkv', '.flv', '.mov', '.m4v', '.webm', '.avi', '.ts'];
    for (final ext in known) {
      if (path.endsWith(ext)) return ext;
    }
    return fallback;
  }

  static String _safeName(String input) {
    var s = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'video' : s;
  }

  static String _join(String a, String b) {
    final sep = Platform.pathSeparator;
    if (a.endsWith(sep) || a.endsWith('/')) return '$a$b';
    return '$a$sep$b';
  }

  static String _taskId(String siteKey, String videoId, String line, int idx, String url) {
    final input = '$siteKey|$videoId|$line|$idx|$url';
    var h1 = 0x811C9DC5;
    var h2 = 0x050C5D1F;
    for (final unit in input.codeUnits) {
      h1 = ((h1 ^ unit) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 ^ (unit + 17)) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }

  static String _friendlyError(Object e) {
    if (e is _DownloadError) return e.message;
    if (e is TimeoutException) return '网络超时，请稍后重试';
    if (e is SocketException) return '网络连接失败';
    if (e is HandshakeException) return '安全连接失败';
    if (e is FileSystemException) return '写入文件失败（空间不足或无权限）';
    final text = e.toString();
    return text.length > 80 ? text.substring(0, 80) : text;
  }
}

/// Table-driven AES-128-CBC decryptor for HLS segments.
class _Aes128Cbc {
  static Uint8List? _inv;
  static Uint8List? _m9;
  static Uint8List? _m11;
  static Uint8List? _m13;
  static Uint8List? _m14;
  final Uint8List _w;

  _Aes128Cbc(Uint8List key) : _w = CmsParser.aesExpandKey(key) {
    _ensureTables();
  }

  static void _ensureTables() {
    if (_inv != null) return;
    _inv = Uint8List.fromList(CmsParser.aesInvSBox);
    _m9 = _table(0x09);
    _m11 = _table(0x0b);
    _m13 = _table(0x0d);
    _m14 = _table(0x0e);
  }

  static Uint8List _table(int factor) {
    final t = Uint8List(256);
    for (var a = 0; a < 256; a++) {
      var p = 0;
      var aa = a;
      var bb = factor;
      for (var i = 0; i < 8; i++) {
        if ((bb & 1) != 0) p ^= aa;
        final hi = aa & 0x80;
        aa = (aa << 1) & 0xFF;
        if (hi != 0) aa ^= 0x1b;
        bb >>= 1;
      }
      t[a] = p;
    }
    return t;
  }

  static void _invShiftSub(Uint8List s, Uint8List tmp, Uint8List inv) {
    for (var i = 0; i < 16; i++) {
      tmp[i] = s[i];
    }
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        s[r + 4 * c] = inv[tmp[r + 4 * ((c - r) & 3)]];
      }
    }
  }

  void _decryptBlock(Uint8List s, Uint8List tmp) {
    final w = _w;
    final inv = _inv!;
    final m9 = _m9!;
    final m11 = _m11!;
    final m13 = _m13!;
    final m14 = _m14!;
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[160 + i];
    }
    for (var round = 9; round >= 1; round--) {
      _invShiftSub(s, tmp, inv);
      final base = round * 16;
      for (var i = 0; i < 16; i++) {
        s[i] ^= w[base + i];
      }
      for (var c = 0; c < 4; c++) {
        final i = c * 4;
        final s0 = s[i];
        final s1 = s[i + 1];
        final s2 = s[i + 2];
        final s3 = s[i + 3];
        s[i] = m14[s0] ^ m11[s1] ^ m13[s2] ^ m9[s3];
        s[i + 1] = m9[s0] ^ m14[s1] ^ m11[s2] ^ m13[s3];
        s[i + 2] = m13[s0] ^ m9[s1] ^ m14[s2] ^ m11[s3];
        s[i + 3] = m11[s0] ^ m13[s1] ^ m9[s2] ^ m14[s3];
      }
    }
    _invShiftSub(s, tmp, inv);
    for (var i = 0; i < 16; i++) {
      s[i] ^= w[i];
    }
  }

  Uint8List decrypt(Uint8List data, Uint8List iv) {
    final usable = data.length - (data.length % 16);
    if (usable <= 0) return data;
    final out = Uint8List(usable);
    final prev = Uint8List.fromList(iv);
    final block = Uint8List(16);
    final cipher = Uint8List(16);
    final tmp = Uint8List(16);
    for (var off = 0; off < usable; off += 16) {
      for (var i = 0; i < 16; i++) {
        final b = data[off + i];
        cipher[i] = b;
        block[i] = b;
      }
      _decryptBlock(block, tmp);
      for (var i = 0; i < 16; i++) {
        out[off + i] = block[i] ^ prev[i];
        prev[i] = cipher[i];
      }
    }
    final pad = out[usable - 1];
    if (pad >= 1 && pad <= 16) {
      var valid = true;
      for (var i = usable - pad; i < usable; i++) {
        if (out[i] != pad) {
          valid = false;
          break;
        }
      }
      if (valid) return Uint8List.sublistView(out, 0, usable - pad);
    }
    return out;
  }
}

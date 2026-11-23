import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
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
  const _DownloadError(this.message);
  @override
  String toString() => message;
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
  const _HlsDownloadWorkItem({
    required this.uri,
    required this.stageFile,
    required this.isAudio,
    this.byteRange,
    this.keyMethod,
    this.keyUri,
    this.iv,
    this.sequence = 0,
  });
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
  static const int segmentConcurrency = 4;
  static const String _defaultUa = 'okhttp/3.15';
  static const int _maxSegmentBytes = 96 * 1024 * 1024;

  final List<DownloadTask> _tasks = [];
  final Set<String> _running = {};
  final Set<String> _stopRequested = {};
  final Set<String> _deleteRequested = {};
  final Map<String, _Meter> _meters = {};
  CmsClient? _client;
  Directory? _root;
  File? _indexFile;
  bool _ready = false;
  Timer? _saveTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 8
    ..userAgent = null
    ..autoUncompress = false;

  bool get isReady => _ready;
  String get rootPath => _root?.path ?? '';
  bool get canOpenFolder =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Newest first for display.
  List<DownloadTask> get tasks {
    final list = List<DownloadTask>.of(_tasks);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  int get activeCount => _tasks.where((t) => t.isActive).length;

  Future<void> init(CmsClient client) async {
    _client = client;
    try {
      _root = await _resolveRoot();
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      _indexFile = File(_join(support.path, 'marco_downloads.json'));
      if (await _indexFile!.exists()) {
        final raw = await _indexFile!.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
            if (task.id.isEmpty) continue;
            if (task.status == DownloadStatus.downloading) {
              task.status = DownloadStatus.queued;
            }
            if (task.status == DownloadStatus.completed &&
                !_verifyCompletedFilesExist(task)) {
              task.status = DownloadStatus.failed;
              task.error = '本地文件已被移动或删除';
              task.progress = 0;
            }
            _tasks.add(task);
          }
        }
      }
    } catch (e) {
      debugPrint('DownloadService init: $e');
    }
    _ready = _root != null;
    notifyListeners();
    _pump();
  }

  /// Simulates a clean app restart in tests by reloading persisted task state
  /// from disk without altering any downloaded files.
  @visibleForTesting
  Future<void> reloadFromDiskForTest(CmsClient client) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _save();
    _tasks.clear();
    _running.clear();
    _stopRequested.clear();
    _deleteRequested.clear();
    _meters.clear();
    await init(client);
  }

  static bool _verifyCompletedFilesExist(DownloadTask task) {
    if (task.filePath.isEmpty) return false;
    final master = File(task.filePath);
    if (!master.existsSync()) return false;
    if (!task.filePath.toLowerCase().endsWith('.m3u8')) return true;
    try {
      final parent = master.parent;
      final content = master.readAsStringSync();
      var referencedCount = 0;
      for (final raw in const LineSplitter().convert(content)) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXT-X-MEDIA:')) {
          final attrs = _parseAttributes(line.substring(line.indexOf(':') + 1));
          final uri = attrs['URI'];
          if (uri != null && uri.isNotEmpty) {
            referencedCount++;
            final subFile = File(_join(parent.path, uri.replaceAll('/', Platform.pathSeparator)));
            if (!subFile.existsSync()) return false;
          }
        } else if (!line.startsWith('#')) {
          referencedCount++;
          final subFile = File(_join(parent.path, line.replaceAll('/', Platform.pathSeparator)));
          if (!subFile.existsSync()) return false;
        }
      }
      return referencedCount > 0;
    } catch (_) {
      return false;
    }
  }

  Future<Directory> _resolveRoot() async {
    Directory? base;
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        base = await getDownloadsDirectory();
        if (base != null) {
          final probe = Directory(_join(base.path, 'Marco Movie'));
          await probe.create(recursive: true);
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

  void resumeAll() {
    for (final t in _tasks) {
      if (t.status == DownloadStatus.paused) t.status = DownloadStatus.queued;
    }
    _scheduleSave(immediate: true);
    notifyListeners();
    _pump();
  }

  Future<void> remove(String id) async {
    final t = _byId(id);
    if (t == null) return;
    _tasks.remove(t);
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
    _meters[t.id] = _Meter(t.receivedBytes, DateTime.now());
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
    final meter = _meters.putIfAbsent(t.id, () => _Meter(t.receivedBytes, now));
    final elapsed = now.difference(meter.time).inMilliseconds;
    if (elapsed >= 800) {
      t.speed = (t.receivedBytes - meter.bytes) * 1000 / elapsed;
      if (t.speed < 0) t.speed = 0;
      meter.bytes = t.receivedBytes;
      meter.time = now;
    }
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

  Future<void> _save() async {
    final file = _indexFile;
    if (file == null) return;
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_tasks.map((t) => t.toJson()).toList()));
      await tmp.rename(file.path);
    } catch (_) {}
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
    String baseName,
  ) async {
    final ext = _extFromUrl(url, fallback: '.mp4');
    final finalFile = File('$baseName$ext');
    final part = File('$baseName$ext.part');
    var existing = await part.exists() ? await part.length() : 0;
    final response = await _open(url, headers, t,
        range: existing > 0 ? 'bytes=$existing-' : null);
    if (response.statusCode == 416 && existing > 0) {
      await response.drain<void>();
      await part.delete();
      return _downloadDirect(t, url, headers, baseName);
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
    t.totalBytes = contentLength > 0 ? existing + contentLength : 0;
    t.receivedBytes = existing;
    BytesBuilder? playlistBuffer;
    var firstChunk = true;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response) {
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
    if (selectedAudioUri != null && selectedAudioUri.isNotEmpty) {
      await _downloadSeparateAudioHls(
        t: t,
        videoPlaylist: playlist,
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
    var done = 0;
    var bytes = 0;
    for (final f in segFiles) {
      if (await f.exists()) {
        done++;
        bytes += await f.length();
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
        final file = segFiles[i];
        if (await file.exists()) continue;
        final seg = playlist.segments[i];
        try {
          var data = await _getBytesRetry(
            seg.uri,
            headers,
            t,
            byteRange: seg.byteRange,
          );
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
            data = _Aes128Cbc(key).decrypt(data, seg.iv ?? _ivFromSequence(seg.sequence));
          }
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(data);
          await tmp.rename(file.path);
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

    await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
    if (_shouldStop(t)) throw const _StopSignal();
    if (failure != null) throw failure!;

    final out = File('$baseName$ext.part');
    final sink = out.openWrite();
    try {
      final firstMap = playlist.firstMap;
      if (firstMap != null) {
        sink.add(await _getBytesRetry(
          firstMap.uri,
          headers,
          t,
          byteRange: firstMap.byteRange,
        ));
      } else if (playlist.mapUri != null) {
        sink.add(await _getBytesRetry(playlist.mapUri!, headers, t));
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

    final stageDir = Directory('$baseName.hls.part');
    await stageDir.create(recursive: true);

    final workItems = <_HlsDownloadWorkItem>[];
    final videoMapFiles = <String, ({String name, File stageFile})>{};
    final audioMapFiles = <String, ({String name, File stageFile})>{};

    void registerMaps(_HlsPlaylist pl, bool isAudio) {
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
          ),
        );
      }
    }

    registerMaps(videoPlaylist, false);
    registerMaps(audioPlaylist, true);

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
        ),
      );
    }

    final total = workItems.length;
    var done = 0;
    var bytes = 0;
    for (final item in workItems) {
      if (await item.stageFile.exists()) {
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
        if (await item.stageFile.exists()) continue;
        try {
          var data = await _getBytesRetry(
            item.uri,
            headers,
            t,
            byteRange: item.byteRange,
          );
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
            data = _Aes128Cbc(key)
                .decrypt(data, item.iv ?? _ivFromSequence(item.sequence));
          }
          if (data.isEmpty) {
            throw _DownloadError(
              item.isAudio ? '独立音轨分片为空，无法保存完整音画' : '视频分片为空',
            );
          }
          final tmp = File('${item.stageFile.path}.tmp');
          await tmp.writeAsBytes(data);
          await tmp.rename(item.stageFile.path);
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

    await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
    if (_shouldStop(t)) throw const _StopSignal();
    if (failure != null) {
      if (audioFailed && failure is! _DownloadError) {
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
      try {
        await stageDir.delete(recursive: true);
      } catch (_) {}

      t.filePath = masterFile.path;
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

  Future<Uint8List> _getBytesOnce(
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
      throw _DownloadError('服务器返回 HTTP ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 45))) {
      if (_shouldStop(t)) throw const _StopSignal();
      builder.add(chunk);
      if (builder.length > _maxSegmentBytes) {
        throw const _DownloadError('单个分片过大');
      }
    }
    final bytes = builder.takeBytes();
    if (byteRange != null && response.statusCode == 200) {
      final end = byteRange.offset + byteRange.length;
      if (byteRange.offset >= 0 && end <= bytes.length) {
        return Uint8List.sublistView(bytes, byteRange.offset, end);
      }
      throw const _DownloadError('分片字节范围越界');
    }
    return bytes;
  }

  Future<Uint8List> _getBytesRetry(
    String url,
    Map<String, String> headers,
    DownloadTask t, {
    _HlsByteRange? byteRange,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_shouldStop(t)) throw const _StopSignal();
      try {
        return await _getBytesOnce(url, headers, t, byteRange: byteRange);
      } on _StopSignal {
        rethrow;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw lastError ?? const _DownloadError('网络请求失败');
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

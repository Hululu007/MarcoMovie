import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'cloud_media_proxy.dart';

enum _TargetKind { auto, playlist, tsSegment, raw, kcache }

class _RegisteredTarget {
  final Uri uri;
  final _TargetKind kind;
  final DiskBlockCache? diskCache;
  final String? cacheKey;
  const _RegisteredTarget(
    this.uri,
    this.kind, {
    this.diskCache,
    this.cacheKey,
  });
}

class _ByteRangeSpec {
  final int start;
  final int? end;
  final int? suffixLength;
  const _ByteRangeSpec({
    required this.start,
    this.end,
    this.suffixLength,
  });

  static _ByteRangeSpec? parse(String? rawHeader) {
    if (rawHeader == null) return null;
    final trimmed = rawHeader.trim();
    if (!trimmed.toLowerCase().startsWith('bytes=')) return null;
    final spec = trimmed.substring(6).split(',').first.trim();
    if (spec.isEmpty) return null;
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right);
      if (suffix == null || suffix <= 0) return null;
      return _ByteRangeSpec(start: 0, suffixLength: suffix);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0) return null;
    if (right.isEmpty) {
      return _ByteRangeSpec(start: start);
    }
    final end = int.tryParse(right);
    if (end == null || end < start) return null;
    return _ByteRangeSpec(start: start, end: end);
  }
}

class DiskCacheEntryMeta {
  final String cacheKey;
  final int? totalLength;
  final String? contentType;
  final String? etag;
  final int lastAccessMs;

  const DiskCacheEntryMeta({
    required this.cacheKey,
    this.totalLength,
    this.contentType,
    this.etag,
    required this.lastAccessMs,
  });

  DiskCacheEntryMeta copyWith({
    int? totalLength,
    String? contentType,
    String? etag,
    int? lastAccessMs,
  }) {
    return DiskCacheEntryMeta(
      cacheKey: cacheKey,
      totalLength: totalLength ?? this.totalLength,
      contentType: contentType ?? this.contentType,
      etag: etag ?? this.etag,
      lastAccessMs: lastAccessMs ?? this.lastAccessMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'cacheKey': cacheKey,
        if (totalLength != null) 'totalLength': totalLength,
        if (contentType != null && contentType!.isNotEmpty)
          'contentType': contentType,
        if (etag != null && etag!.isNotEmpty) 'etag': etag,
        'lastAccessMs': lastAccessMs,
      };

  static DiskCacheEntryMeta? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final key = (raw['cacheKey'] ?? '').toString();
    if (key.isEmpty) return null;
    return DiskCacheEntryMeta(
      cacheKey: key,
      totalLength: (raw['totalLength'] as num?)?.toInt(),
      contentType: raw['contentType']?.toString(),
      etag: raw['etag']?.toString(),
      lastAccessMs: (raw['lastAccessMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 256 KiB aligned block-level disk cache for seekable desktop media streams
/// (`/kcache/<sid>`), with atomic block writes, ETag invalidation, and LRU eviction.
class DiskBlockCache {
  static const int blockSize = 256 * 1024; // 256 KiB
  static const int defaultMaxBytes = 512 * 1024 * 1024; // 512 MB
  static const List<int> supportedMaxMbOptions = <int>[0, 256, 512, 1024, 2048];

  static Directory defaultCacheDirectory() {
    if (Platform.isWindows) {
      final localAppData = (Platform.environment['LOCALAPPDATA'] ?? '').trim();
      if (localAppData.isNotEmpty) {
        return Directory(
          '$localAppData${Platform.pathSeparator}MarcoMovie${Platform.pathSeparator}cache${Platform.pathSeparator}media-cache',
        );
      }
    }
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}MarcoMovie${Platform.pathSeparator}cache${Platform.pathSeparator}media-cache',
    );
  }

  static final DiskBlockCache instance = DiskBlockCache();

  final Directory? _explicitDirectory;
  final DateTime Function() _clock;
  int _maxBytes;
  Future<void> _ioChain = Future<void>.value();
  int _tmpSeq = 0;

  DiskBlockCache({
    Directory? directory,
    int maxBytes = defaultMaxBytes,
    DateTime Function()? clock,
  })  : _explicitDirectory = directory,
        _maxBytes = maxBytes < 0 ? 0 : maxBytes,
        _clock = clock ?? DateTime.now;

  Directory get cacheDirectory => _explicitDirectory ?? defaultCacheDirectory();
  int get maxBytes => _maxBytes;
  bool get isEnabled => _maxBytes > 0;

  static String hashKey(String cacheKey) =>
      sha256.convert(utf8.encode(cacheKey)).toString();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _ioChain.then((_) => action());
    _ioChain = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Directory _entryDirForHash(String keyHash) =>
      Directory('${cacheDirectory.path}${Platform.pathSeparator}$keyHash');

  File _metaFileForHash(String keyHash) =>
      File('${_entryDirForHash(keyHash).path}${Platform.pathSeparator}meta.json');

  File _blockFileForHash(String keyHash, int blockIndex) => File(
      '${_entryDirForHash(keyHash).path}${Platform.pathSeparator}$blockIndex.blk');

  Future<void> setMaxBytes(int bytes) => _serialized(() async {
        _maxBytes = bytes < 0 ? 0 : bytes;
        if (_maxBytes == 0) {
          await _clearAllInternal();
          return;
        }
        await _evictLruInternal();
      });

  Future<void> setMaxMegabytes(int mb) =>
      setMaxBytes(mb <= 0 ? 0 : mb * 1024 * 1024);

  Future<int> currentCacheBytes() => _serialized(() async {
        return _computeCurrentBytesSync();
      });

  Future<void> flush() => _serialized(() async {});

  int _computeCurrentBytesSync() {
    final root = cacheDirectory;
    if (!root.existsSync()) return 0;
    var total = 0;
    for (final entry in root.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      for (final file in entry.listSync(followLinks: false)) {
        if (file is File && file.path.endsWith('.blk')) {
          try {
            total += file.lengthSync();
          } catch (_) {}
        }
      }
    }
    return total;
  }

  Future<void> clearDiskCache() => _serialized(_clearAllInternal);

  Future<void> _clearAllInternal() async {
    final root = cacheDirectory;
    if (!root.existsSync()) return;
    for (final entity in root.listSync(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }

  DiskCacheEntryMeta? _readMetaSync(String keyHash) {
    final f = _metaFileForHash(keyHash);
    if (!f.existsSync()) return null;
    try {
      return DiskCacheEntryMeta.fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMetaAtomic(String keyHash, DiskCacheEntryMeta meta) async {
    final dir = _entryDirForHash(keyHash);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final tmp = File(
      '${dir.path}${Platform.pathSeparator}meta.${++_tmpSeq}.tmp',
    );
    await tmp.writeAsString(jsonEncode(meta.toJson()), flush: true);
    final dest = _metaFileForHash(keyHash);
    if (dest.existsSync()) {
      try {
        await dest.delete();
      } catch (_) {}
    }
    await tmp.rename(dest.path);
  }

  Future<DiskCacheEntryMeta?> getMeta(String cacheKey) => _serialized(() async {
        if (_maxBytes <= 0) return null;
        return _readMetaSync(hashKey(cacheKey));
      });

  Future<void> updateMeta(
    String cacheKey, {
    int? totalLength,
    String? contentType,
    String? etag,
  }) =>
      _serialized(() async {
        if (_maxBytes <= 0) return;
        final keyHash = hashKey(cacheKey);
        final existing = _readMetaSync(keyHash);
        if (existing != null &&
            etag != null &&
            etag.isNotEmpty &&
            existing.etag != null &&
            existing.etag!.isNotEmpty &&
            existing.etag != etag) {
          final dir = _entryDirForHash(keyHash);
          if (dir.existsSync()) {
            try {
              await dir.delete(recursive: true);
            } catch (_) {}
          }
        }
        final nowMs = _clock().millisecondsSinceEpoch;
        final base = _readMetaSync(keyHash) ??
            DiskCacheEntryMeta(cacheKey: cacheKey, lastAccessMs: nowMs);
        await _writeMetaAtomic(
          keyHash,
          base.copyWith(
            totalLength: totalLength,
            contentType: contentType,
            etag: etag,
            lastAccessMs: nowMs,
          ),
        );
      });

  Future<Uint8List?> readBlock(String cacheKey, int blockIndex) =>
      _serialized(() async {
        if (_maxBytes <= 0 || blockIndex < 0) return null;
        final keyHash = hashKey(cacheKey);
        final f = _blockFileForHash(keyHash, blockIndex);
        if (!f.existsSync()) return null;
        try {
          final bytes = await f.readAsBytes();
          if (bytes.isEmpty || bytes.length > blockSize) return null;
          final now = _clock();
          try {
            await f.setLastModified(now);
          } catch (_) {}
          final meta = _readMetaSync(keyHash);
          if (meta != null) {
            await _writeMetaAtomic(
              keyHash,
              meta.copyWith(lastAccessMs: now.millisecondsSinceEpoch),
            );
          }
          return bytes;
        } catch (_) {
          return null;
        }
      });

  Future<bool> hasBlock(String cacheKey, int blockIndex) =>
      _serialized(() async {
        if (_maxBytes <= 0 || blockIndex < 0) return false;
        return _blockFileForHash(hashKey(cacheKey), blockIndex).existsSync();
      });

  Future<void> writeBlock(
    String cacheKey,
    int blockIndex,
    Uint8List data, {
    int? totalLength,
    String? contentType,
    String? etag,
  }) =>
      _serialized(() async {
        if (_maxBytes <= 0 ||
            blockIndex < 0 ||
            data.isEmpty ||
            data.length > blockSize ||
            data.length > _maxBytes) {
          return;
        }
        final keyHash = hashKey(cacheKey);
        final dir = _entryDirForHash(keyHash);
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        final existing = _readMetaSync(keyHash);
        if (existing != null &&
            etag != null &&
            etag.isNotEmpty &&
            existing.etag != null &&
            existing.etag!.isNotEmpty &&
            existing.etag != etag) {
          for (final item in dir.listSync(followLinks: false)) {
            if (item is File && item.path.endsWith('.blk')) {
              try {
                await item.delete();
              } catch (_) {}
            }
          }
        }

        final tmp = File(
          '${dir.path}${Platform.pathSeparator}$blockIndex.${++_tmpSeq}.tmp',
        );
        await tmp.writeAsBytes(data, flush: true);
        final dest = _blockFileForHash(keyHash, blockIndex);
        if (dest.existsSync()) {
          try {
            await dest.delete();
          } catch (_) {}
        }
        await tmp.rename(dest.path);
        final now = _clock();
        try {
          await dest.setLastModified(now);
        } catch (_) {}

        final base = _readMetaSync(keyHash) ??
            DiskCacheEntryMeta(
              cacheKey: cacheKey,
              lastAccessMs: now.millisecondsSinceEpoch,
            );
        await _writeMetaAtomic(
          keyHash,
          base.copyWith(
            totalLength: totalLength,
            contentType: contentType,
            etag: etag,
            lastAccessMs: now.millisecondsSinceEpoch,
          ),
        );

        await _evictLruInternal(
          protectedKeyHash: keyHash,
          protectedBlockIndex: blockIndex,
        );
      });

  Future<void> _evictLruInternal({
    String? protectedKeyHash,
    int? protectedBlockIndex,
  }) async {
    final root = cacheDirectory;
    if (!root.existsSync()) return;
    final candidates = <({
      String keyHash,
      int blockIndex,
      int size,
      int accessMs,
      File file,
    })>[];
    var total = 0;

    for (final entry in root.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final keyHash = entry.path.split(Platform.pathSeparator).last;
      final meta = _readMetaSync(keyHash);
      final metaAccessMs = meta?.lastAccessMs ?? 0;
      for (final file in entry.listSync(followLinks: false)) {
        if (file is! File) continue;
        final name = file.path.split(Platform.pathSeparator).last;
        if (name.endsWith('.tmp')) {
          try {
            await file.delete();
          } catch (_) {}
          continue;
        }
        if (!name.endsWith('.blk')) continue;
        final idx = int.tryParse(name.substring(0, name.length - 4));
        if (idx == null) continue;
        try {
          final stat = file.statSync();
          total += stat.size;
          final modMs = stat.modified.millisecondsSinceEpoch;
          // Combine block mtime with entry access time (max ensures entry reads bump priority,
          // while mtime differentiates blocks inside the same entry).
          final accessMs = modMs > metaAccessMs ? modMs : metaAccessMs;
          candidates.add((
            keyHash: keyHash,
            blockIndex: idx,
            size: stat.size,
            accessMs: accessMs,
            file: file,
          ));
        } catch (_) {}
      }
    }

    if (total <= _maxBytes) return;

    candidates.sort((a, b) {
      final cmp = a.accessMs.compareTo(b.accessMs);
      if (cmp != 0) return cmp;
      final kCmp = a.keyHash.compareTo(b.keyHash);
      if (kCmp != 0) return kCmp;
      return a.blockIndex.compareTo(b.blockIndex);
    });

    final touchedDirs = <String>{};
    for (final c in candidates) {
      if (total <= _maxBytes) break;
      if (c.keyHash == protectedKeyHash && c.blockIndex == protectedBlockIndex) {
        continue;
      }
      try {
        await c.file.delete();
        total -= c.size;
        touchedDirs.add(c.keyHash);
      } catch (_) {}
    }

    for (final keyHash in touchedDirs) {
      final dir = _entryDirForHash(keyHash);
      if (!dir.existsSync()) continue;
      final hasBlocks = dir
          .listSync(followLinks: false)
          .any((f) => f is File && f.path.endsWith('.blk'));
      if (!hasBlocks) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}

class _StoredCookie {
  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final DateTime? expiresAt;

  const _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    this.expiresAt,
  });

  bool matches(Uri uri, DateTime now) {
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    final reqHost = uri.host.toLowerCase();
    if (hostOnly) {
      if (reqHost != domain) return false;
    } else {
      if (reqHost != domain && !reqHost.endsWith('.$domain')) return false;
    }
    final reqPath = uri.path.isEmpty ? '/' : uri.path;
    if (path == '/' || reqPath == path) return true;
    if (reqPath.startsWith(path)) {
      return path.endsWith('/') || reqPath.codeUnitAt(path.length) == 0x2F;
    }
    return false;
  }
}

class _SessionCookieJar {
  final Map<String, _StoredCookie> _cookies = {};

  static List<String> splitSetCookieHeader(String raw) {
    final result = <String>[];
    var start = 0;
    var inExpires = false;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw.codeUnitAt(i);
      if (ch == 0x3B /* ; */) {
        inExpires = false;
      } else if (!inExpires &&
          i + 8 <= raw.length &&
          raw.substring(i, i + 8).toLowerCase() == 'expires=') {
        inExpires = true;
      } else if (ch == 0x2C /* , */) {
        if (inExpires) {
          inExpires = false;
          continue;
        }
        final rest = raw.substring(i + 1).trimLeft();
        final semi = rest.indexOf(';');
        final eq = rest.indexOf('=');
        if (eq > 0 && (semi < 0 || eq < semi)) {
          final piece = raw.substring(start, i).trim();
          if (piece.isNotEmpty) result.add(piece);
          start = i + 1;
        }
      }
    }
    final tail = raw.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }

  void storeFromHeaders(
      Map<String, String> responseHeaders, Uri requestUri, DateTime now) {
    String? rawSetCookie;
    for (final entry in responseHeaders.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        rawSetCookie = entry.value;
        break;
      }
    }
    if (rawSetCookie == null || rawSetCookie.trim().isEmpty) return;
    for (final header in splitSetCookieHeader(rawSetCookie)) {
      final parts = header.split(';');
      if (parts.isEmpty) continue;
      final nv = parts.first.trim();
      final eq = nv.indexOf('=');
      if (eq <= 0) continue;
      final name = nv.substring(0, eq).trim();
      final value = nv.substring(eq + 1).trim();
      if (name.isEmpty) continue;

      final reqHost = requestUri.host.toLowerCase();
      var domain = reqHost;
      var hostOnly = true;
      var path = _defaultCookiePath(requestUri.path);
      DateTime? expiresAt;

      for (final rawAttr in parts.skip(1)) {
        final attr = rawAttr.trim();
        if (attr.isEmpty) continue;
        final aEq = attr.indexOf('=');
        final aKey =
            (aEq < 0 ? attr : attr.substring(0, aEq)).trim().toLowerCase();
        final aVal = aEq < 0 ? '' : attr.substring(aEq + 1).trim();
        if (aKey == 'domain' && aVal.isNotEmpty) {
          final clean = aVal.replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
          if (clean.contains('.') &&
              InternetAddress.tryParse(clean) == null &&
              (reqHost == clean || reqHost.endsWith('.$clean'))) {
            domain = clean;
            hostOnly = false;
          }
        } else if (aKey == 'path' && aVal.startsWith('/')) {
          path = aVal;
        } else if (aKey == 'max-age') {
          final secs = int.tryParse(aVal);
          if (secs != null) {
            expiresAt = secs <= 0
                ? now.subtract(const Duration(seconds: 1))
                : now.add(Duration(seconds: secs));
          }
        } else if (aKey == 'expires' && expiresAt == null && aVal.isNotEmpty) {
          try {
            expiresAt = HttpDate.parse(aVal);
          } catch (_) {}
        }
      }

      final storageKey = '$domain|$hostOnly|$path|$name';
      if (value.isEmpty || (expiresAt != null && !expiresAt.isAfter(now))) {
        _cookies.remove(storageKey);
      } else if (_cookies.length < 256 || _cookies.containsKey(storageKey)) {
        _cookies[storageKey] = _StoredCookie(
          name: name,
          value: value,
          domain: domain,
          hostOnly: hostOnly,
          path: path,
          expiresAt: expiresAt,
        );
      }
    }
  }

  Map<String, String> matchingCookies(Uri uri, DateTime now) {
    final out = <String, String>{};
    final matched = _cookies.values.where((c) => c.matches(uri, now)).toList()
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    for (final c in matched) {
      out[c.name] = c.value;
    }
    return out;
  }

  void clear() => _cookies.clear();

  static String _defaultCookiePath(String reqPath) {
    if (reqPath.isEmpty || !reqPath.startsWith('/')) return '/';
    final lastSlash = reqPath.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : reqPath.substring(0, lastSlash);
  }
}

/// Session-scoped loopback media gateway (`http://127.0.0.1:<port>/<capability>/...`).
///
/// Handles anti-leech `Referer`/`User-Agent`/`Origin`, dynamic `Set-Cookie` jars,
/// cross-domain CDN redirects with strict credential-origin boundaries, extensionless
/// HLS `.m3u8` manifest rewriting, and fake PNG/JPG/GIF header stripping on MPEG-TS
/// segments so `libmpv` receives a clean local stream.
class LocalMediaLease {
  static bool defaultHlsAdStripEnabled = true;

  LocalMediaLease._(
    this._server,
    this._client,
    this._ownsClient,
    Uri initialTarget,
    this._headers,
    this._isCancelled,
    this._capability,
    this._clock,
    this._isLive,
    this._stripHlsAds,
    this._adPatterns,
    this._diskCache,
    bool enableDiskCache,
    String? diskCacheKey,
  )   : _initialOrigin = _originOf(initialTarget),
        _created = _clock() {
    final initialKind = _inferInitialKind(initialTarget);
    if (enableDiskCache && !_isLive && initialKind != _TargetKind.playlist) {
      _initialUrl = registerDiskCacheStream(
        initialTarget,
        cacheKey: diskCacheKey,
        diskCache: _diskCache,
      );
    } else {
      _initialUrl = _register(initialTarget, initialKind);
    }
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sweep());
  }

  static const int _maxConcurrentRequests = 24;
  static const int _flushThresholdBytes = 4 * 1024 * 1024;
  static const int _liveFlushThresholdBytes = 64 * 1024;
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;
  static const int _sniffPrefixBytes = 4096;
  static const String _defaultBrowserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Set<String> _originBoundHeaderNames = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'cookie2',
    'x-api-key',
    'x-emby-token',
    'x-plex-token',
  };

  static const Set<String> _hopByHopHeaderNames = {
    'host',
    'connection',
    'keep-alive',
    'proxy-connection',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'content-length',
  };

  final HttpServer _server;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _initialOrigin;
  final Map<String, String> _headers;
  final bool Function() _isCancelled;
  final String _capability;
  final DateTime Function() _clock;
  final bool _isLive;
  final bool _stripHlsAds;
  final List<String> _adPatterns;
  final DiskBlockCache _diskCache;
  final DateTime _created;
  final _cookieJar = _SessionCookieJar();
  final _targets = <String, _RegisteredTarget>{};
  final _paths = <String, String>{};
  final _requests = <HttpRequest>{};
  final _upstreams = <StreamSubscription<List<int>>>{};
  int _kcacheSeq = 0;
  late final Uri _initialUrl;
  http.Client? _directOnlyClient;
  Timer? _timer;
  bool _closed = false;
  int? _lastUpstreamStatusCode;
  String? _lastUpstreamHost;
  Object? _lastUpstreamError;

  Uri get url => _initialUrl;
  bool get isClosed => _closed;
  int? get lastUpstreamStatusCode => _lastUpstreamStatusCode;
  String? get lastUpstreamHost => _lastUpstreamHost;
  Object? get lastUpstreamError => _lastUpstreamError;

  /// Registers a seekable stream on `/kcache/<sid>` backed by [DiskBlockCache].
  Uri registerDiskCacheStream(
    Uri target, {
    String? cacheKey,
    DiskBlockCache? diskCache,
  }) {
    if (_closed || !_canRegisterTarget(target)) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    final resolvedCacheKey =
        (cacheKey != null && cacheKey.trim().isNotEmpty)
            ? cacheKey.trim()
            : target.toString();
    final key = '${_TargetKind.kcache.name}|$resolvedCacheKey|$target';
    final path = _paths.putIfAbsent(key, () {
      final sid = '${_capability}_${_kcacheSeq++}';
      final p = '/kcache/$sid';
      _targets[p] = _RegisteredTarget(
        target,
        _TargetKind.kcache,
        diskCache: diskCache ?? _diskCache,
        cacheKey: resolvedCacheKey,
      );
      return p;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  /// Registers a companion stream (e.g. separate DASH `.m4s` audio track) onto
  /// this session's loopback gateway so it receives the same anti-leech headers.
  Uri? tryRegisterCompanionMedia(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || !shouldProxy(parsed) || !_canRegisterTarget(parsed)) {
      return null;
    }
    try {
      return _register(parsed, _inferInitialKind(parsed));
    } catch (_) {
      return null;
    }
  }

  static bool isLoopbackHost(String host) {
    final bare = host.trim().toLowerCase();
    if (bare.isEmpty) return false;
    return bare == '127.0.0.1' ||
        bare == 'localhost' ||
        bare == '::1' ||
        bare == '[::1]' ||
        bare.startsWith('127.');
  }

  static bool shouldProxy(Uri? uri) =>
      uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !isLoopbackHost(uri.host);

  static bool isPrivateOrReservedTarget(Uri uri) {
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty) return true;
    if (isLoopbackHost(host) || host.endsWith('.localhost')) return true;
    final cleanHost = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    final ip = InternetAddress.tryParse(cleanHost);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    final raw = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0], b = raw[1];
      if (a == 0 || a == 10 || a == 127) return true;
      if (a == 169 && b == 254) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (ip.type == InternetAddressType.IPv6 && raw.length == 16) {
      final allZero = raw.every((b) => b == 0);
      if (allZero) return true;
      // Unique local fc00::/7
      if ((raw[0] & 0xFE) == 0xFC) return true;
      // IPv4-mapped ::ffff:a.b.c.d
      final v4Mapped = raw.take(10).every((b) => b == 0) &&
          raw[10] == 0xFF &&
          raw[11] == 0xFF;
      if (v4Mapped) {
        final v4 = '${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}';
        return isPrivateOrReservedTarget(Uri(scheme: 'http', host: v4));
      }
    }
    return false;
  }

  /// Detects a fake image/padding prefix (e.g. PNG/JPG/GIF/BMP header) prepended
  /// before an unencrypted 188-byte MPEG-TS packet stream and returns its byte offset.
  /// Returns `0` when the buffer is already standard media or no TS sync lock exists.
  static int findDisguisedTsOffset(Uint8List prefix) {
    if (prefix.length < 189 || prefix[0] == 0x47) return 0;
    // Standard elementary / container signatures that must never be stripped:
    // ID3 (packed audio HLS), #EXTM3U, WEBVTT, FLV, EBML (MKV/WebM), MP4/fMP4 boxes.
    if (prefix.length >= 3 &&
        prefix[0] == 0x49 &&
        prefix[1] == 0x44 &&
        prefix[2] == 0x33) {
      return 0;
    }
    if (prefix.length >= 7) {
      var s = 0;
      if (prefix[0] == 0xEF && prefix[1] == 0xBB && prefix[2] == 0xBF) s = 3;
      while (s < prefix.length &&
          (prefix[s] == 0x20 ||
              prefix[s] == 0x09 ||
              prefix[s] == 0x0D ||
              prefix[s] == 0x0A)) {
        s++;
      }
      if (s + 7 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 7)) == '#EXTM3U') {
        return 0;
      }
      if (s + 6 <= prefix.length &&
          latin1.decode(prefix.sublist(s, s + 6)) == 'WEBVTT') {
        return 0;
      }
    }
    if (prefix.length >= 4 &&
        ((prefix[0] == 0x46 && prefix[1] == 0x4C && prefix[2] == 0x56) ||
            (prefix[0] == 0x1A &&
                prefix[1] == 0x45 &&
                prefix[2] == 0xDF &&
                prefix[3] == 0xA3))) {
      return 0;
    }
    if (prefix.length >= 8) {
      final box = latin1.decode(prefix.sublist(4, 8));
      if (const {'ftyp', 'styp', 'moof', 'moov', 'mdat', 'sidx', 'free', 'wide'}
          .contains(box)) {
        return 0;
      }
    }

    final maxOffset = math.min(prefix.length - 189, 3072);
    for (var i = 1; i <= maxOffset; i++) {
      if (prefix[i] != 0x47) continue;
      if (prefix.length >= i + 377) {
        if (prefix[i + 188] == 0x47 && prefix[i + 376] == 0x47) {
          return i;
        }
      } else if (prefix[i + 188] == 0x47) {
        return i;
      }
    }
    return 0;
  }

  static Future<LocalMediaLease> open({
    required Uri target,
    Map<String, String> headers = const {},
    required bool Function() isCancelled,
    DateTime Function()? clock,
    http.Client? client,
    bool isLive = false,
    bool? stripHlsAds,
    List<String> adPatterns = const [],
    bool enableDiskCache = false,
    DiskBlockCache? diskCache,
    String? diskCacheKey,
  }) async {
    if (!shouldProxy(target)) {
      throw const FormatException('本地媒体代理仅接受远程 HTTP/HTTPS 流地址');
    }
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty ||
          key.contains('\r') ||
          key.contains('\n') ||
          value.contains('\r') ||
          value.contains('\n')) {
        continue;
      }
      if (_hopByHopHeaderNames.contains(key.toLowerCase())) continue;
      sanitized[key] = value;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..autoCompress = false;
    final random = math.Random.secure();
    final capability = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final ownsClient = client == null;
    final transport =
        client ?? _createDirectFallbackHttpClient(isLive: isLive);
    return LocalMediaLease._(
      server,
      transport,
      ownsClient,
      target,
      sanitized,
      isCancelled,
      capability,
      clock ?? DateTime.now,
      isLive,
      stripHlsAds ?? defaultHlsAdStripEnabled,
      List<String>.unmodifiable(adPatterns),
      diskCache ?? DiskBlockCache.instance,
      enableDiskCache,
      diskCacheKey,
    );
  }

  static http.Client _createDirectFallbackHttpClient({
    bool directOnly = false,
    bool isLive = false,
  }) {
    final io = HttpClient()
      ..autoUncompress = true
      ..maxConnectionsPerHost = 12
      ..connectionTimeout = Duration(seconds: isLive ? 8 : 15)
      ..idleTimeout = const Duration(seconds: 30);
    if (isLive) {
      // Many public IPTV HTTPS edges use self-signed or incomplete cert chains.
      io.badCertificateCallback = (_, __, ___) => true;
    }
    if (directOnly) {
      io.findProxy = (_) => 'DIRECT';
    }
    return IOClient(io);
  }

  static bool _isDeadLocalProxyError(Uri targetUri, Object error) {
    if (isLoopbackHost(targetUri.host)) return false;
    if (error is SocketException) {
      final host = error.address?.host ?? '';
      if (error.address?.isLoopback == true || isLoopbackHost(host)) {
        return true;
      }
    }
    if (error is http.ClientException || error is SocketException) {
      final msg = error.toString();
      final hitsLoopback = msg.contains('address = 127.0.0.1') ||
          msg.contains('address = ::1') ||
          msg.contains('address = localhost');
      final refused = msg.contains('Connection refused') ||
          msg.contains('errno = 61') ||
          msg.contains('errno = 111') ||
          msg.contains('errno = 10061');
      return hitsLoopback && refused;
    }
    return false;
  }

  static Uri _originOf(Uri uri) => Uri(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        port: uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80),
      );

  static bool _sameOrigin(Uri a, Uri b) =>
      _originOf(a).scheme == _originOf(b).scheme &&
      _originOf(a).host == _originOf(b).host &&
      _originOf(a).port == _originOf(b).port;

  static _TargetKind _inferInitialKind(Uri uri) {
    final lower = '${uri.path}?${uri.query}'.toLowerCase();
    if (lower.contains('.m3u8')) return _TargetKind.playlist;
    return _TargetKind.auto;
  }

  bool _canRegisterTarget(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
    if (_sameOrigin(uri, _initialOrigin)) return true;
    if (isPrivateOrReservedTarget(uri)) return false;
    return uri.host.contains('.') || InternetAddress.tryParse(uri.host) != null;
  }

  Uri _register(Uri target, _TargetKind kind) {
    if (_closed || !_canRegisterTarget(target)) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    if (_isLive && _targets.length >= 512) {
      final keepPath = _targets.isNotEmpty ? _targets.keys.first : '';
      final removableKeys = _paths.keys
          .where((k) => _paths[k] != keepPath)
          .take(128)
          .toList(growable: false);
      for (final oldKey in removableKeys) {
        final oldPath = _paths.remove(oldKey);
        if (oldPath != null) _targets.remove(oldPath);
      }
    }
    if (_targets.length >= 65536) {
      throw const FormatException('媒体分片或重定向目标不受信任');
    }
    final key = '${kind.name}|$target';
    final path = _paths.putIfAbsent(key, () {
      String suffix;
      if (_targets.isEmpty) {
        final lowerPath = target.path.toLowerCase();
        if (lowerPath.endsWith('.m3u8') || kind == _TargetKind.playlist) {
          suffix = 'stream.m3u8';
        } else if (lowerPath.endsWith('.mp4')) {
          suffix = 'stream.mp4';
        } else if (lowerPath.endsWith('.mkv')) {
          suffix = 'stream.mkv';
        } else if (lowerPath.endsWith('.flv')) {
          suffix = 'stream.flv';
        } else {
          suffix = 'stream';
        }
      } else {
        String ext;
        if (kind == _TargetKind.playlist) {
          ext = '.m3u8';
        } else if (kind == _TargetKind.tsSegment) {
          ext = '.ts';
        } else {
          final lowerPath = target.path.toLowerCase();
          const safeExts = [
            '.m4s',
            '.mp4',
            '.ts',
            '.key',
            '.aac',
            '.vtt',
            '.mkv',
            '.flv',
          ];
          ext = safeExts.firstWhere(
            (candidate) => lowerPath.endsWith(candidate),
            orElse: () => '',
          );
        }
        suffix = 'part-${_targets.length}$ext';
      }
      final p = '/$_capability/$suffix';
      _targets[p] = _RegisteredTarget(target, kind);
      return p;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  Future<void> _sweep() async {
    if (_closed) return;
    if (_isCancelled() ||
        _clock().difference(_created) > const Duration(hours: 12)) {
      await close();
    }
  }

  bool _isAllowedLocalRequest(HttpRequest request) {
    final hostHeader = request.headers.value(HttpHeaders.hostHeader);
    if (hostHeader != null && hostHeader.isNotEmpty) {
      final hostOnly = hostHeader.startsWith('[')
          ? hostHeader.substring(0, hostHeader.indexOf(']') + 1)
          : hostHeader.split(':').first;
      if (!isLoopbackHost(hostOnly)) return false;
    }
    final origin = request.headers.value('origin');
    if (origin != null && origin.isNotEmpty) return false;
    final secFetch = request.headers.value('sec-fetch-site')?.trim().toLowerCase();
    if (secFetch != null &&
        secFetch.isNotEmpty &&
        secFetch != 'none' &&
        secFetch != 'same-origin') {
      return false;
    }
    return true;
  }

  Map<String, String> _providerScopedRedirectCookies(Uri target) {
    final rawCookie = _headers.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'cookie',
          orElse: () => const MapEntry('', ''),
        )
        .value;
    if (rawCookie.isEmpty) return const {};
    Set<String>? allowedKeys;
    if (CloudMediaLease.isTrustedQuarkMedia(target)) {
      allowedKeys = const {'__pus', '__puus'};
    } else if (CloudMediaLease.isTrustedUcMedia(target)) {
      allowedKeys = const {'__pus', '__puus', '__pugs'};
    }
    if (allowedKeys == null) return const {};
    final scoped = <String, String>{};
    for (final pair in rawCookie.split(';')) {
      final trimmed = pair.trim();
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final name = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      if (allowedKeys.contains(name) && value.isNotEmpty) {
        scoped[name] = value;
      }
    }
    return scoped;
  }

  Map<String, String> _buildUpstreamHeaders(
    Uri target, {
    String? range,
    String? ifRange,
    required bool allowRange,
  }) {
    final sameOrigin = _sameOrigin(target, _initialOrigin);
    final out = <String, String>{};
    var hasUa = false;
    String? initialCookie;

    for (final entry in _headers.entries) {
      final lower = entry.key.toLowerCase();
      if (_hopByHopHeaderNames.contains(lower)) continue;
      if (!sameOrigin && _originBoundHeaderNames.contains(lower)) continue;
      if (lower == 'user-agent') hasUa = true;
      if (lower == 'cookie') {
        initialCookie = entry.value;
        continue;
      }
      out[entry.key] = entry.value;
    }
    if (!hasUa) {
      out['User-Agent'] = _defaultBrowserUa;
    }

    final mergedCookies = <String, String>{};
    if (initialCookie != null && initialCookie.isNotEmpty) {
      for (final pair in initialCookie.split(';')) {
        final trimmed = pair.trim();
        final eq = trimmed.indexOf('=');
        if (eq > 0) {
          mergedCookies[trimmed.substring(0, eq).trim()] =
              trimmed.substring(eq + 1).trim();
        }
      }
    } else if (!sameOrigin) {
      // Cloud media CDN redirects (e.g. Quark *.quark.cn edge redirect or a
      // T4/Gateway proxy 302 to *.quark.cn) require the provider's own session
      // cookie without leaking unrelated portal cookies or Authorization.
      mergedCookies.addAll(_providerScopedRedirectCookies(target));
    }
    mergedCookies.addAll(_cookieJar.matchingCookies(target, _clock()));
    if (mergedCookies.isNotEmpty) {
      out['Cookie'] =
          mergedCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    }

    if (allowRange && range != null && range.isNotEmpty) {
      out['Accept-Encoding'] = 'identity';
      out['Range'] = range;
      if (ifRange != null && ifRange.isNotEmpty) {
        out['If-Range'] = ifRange;
      }
    }
    return out;
  }

  Future<(http.StreamedResponse, Uri)> _sendWithRedirects(
    Uri initialTarget, {
    required String method,
    String? range,
    String? ifRange,
    required bool allowRange,
  }) async {
    var current = initialTarget;
    for (var redirects = 0;; redirects++) {
      http.Request makeReq() => http.Request(method, current)
        ..followRedirects = false
        ..headers.addAll(_buildUpstreamHeaders(
          current,
          range: range,
          ifRange: ifRange,
          allowRange: allowRange,
        ));
      final requestTimeout = Duration(seconds: _isLive ? 15 : 25);
      http.StreamedResponse response;
      try {
        final activeTransport = _directOnlyClient ?? _client;
        response = await activeTransport
            .send(makeReq())
            .timeout(requestTimeout);
      } catch (error) {
        if (_ownsClient &&
            _directOnlyClient == null &&
            !_closed &&
            !_isCancelled() &&
            _isDeadLocalProxyError(current, error)) {
          _directOnlyClient = _createDirectFallbackHttpClient(
            directOnly: true,
            isLive: _isLive,
          );
          response = await _directOnlyClient!
              .send(makeReq())
              .timeout(requestTimeout);
        } else {
          rethrow;
        }
      }
      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('cancelled');
      }
      _cookieJar.storeFromHeaders(response.headers, current, _clock());

      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return (response, current);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null || location.trim().isEmpty || redirects >= 10) {
        throw const FormatException('媒体重定向次数过多或地址缺失');
      }
      final next = current.resolve(location.trim()).removeFragment();
      if (!_canRegisterTarget(next)) {
        throw const FormatException('媒体重定向目标不受信任');
      }
      current = next;
    }
  }

  static bool _startsWithM3u8Magic(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    if (bytes.length - i < 7) return false;
    return latin1.decode(bytes.sublist(i, i + 7)) == '#EXTM3U';
  }

  static bool _couldBeM3u8Prefix(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    if (i >= bytes.length) return true;
    const magic = <int>[0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // #EXTM3U
    final remaining = bytes.length - i;
    final checkLen = remaining < magic.length ? remaining : magic.length;
    for (var j = 0; j < checkLen; j++) {
      if (bytes[i + j] != magic[j]) return false;
    }
    return true;
  }

  static bool _hasNonZeroRangeStart(String? range) {
    if (range == null || range.isEmpty) return false;
    final match = RegExp(r'^bytes=(\d+)-').firstMatch(range.trim());
    if (match == null) return true;
    return (int.tryParse(match.group(1)!) ?? 0) > 0;
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed || _isCancelled()) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (!_isAllowedLocalRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final registered = _targets[request.uri.path];
    if (registered == null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    if (_requests.length >= _maxConcurrentRequests) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    _requests.add(request);
    try {
      if (registered.kind == _TargetKind.kcache) {
        await _serveKcacheRequest(request, registered);
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final isExplicitPlaylist = registered.kind == _TargetKind.playlist ||
          registered.uri.path.toLowerCase().endsWith('.m3u8');
      final (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: request.method,
        range: range,
        ifRange: ifRange,
        allowRange: !isExplicitPlaylist && !_isLive,
      );

      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _lastUpstreamStatusCode = response.statusCode;
        _lastUpstreamHost = finalTarget.host;
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = response.statusCode;
        return;
      }
      _lastUpstreamStatusCode = response.statusCode;
      _lastUpstreamHost = finalTarget.host;
      _lastUpstreamError = null;

      final mime = (response.headers['content-type'] ?? '').toLowerCase();
      final knownPlaylist = isExplicitPlaylist ||
          mime.contains('mpegurl') ||
          finalTarget.path.toLowerCase().endsWith('.m3u8');

      if (request.method == 'HEAD') {
        _copyResponseHeaders(response, request.response);
        if (knownPlaylist) {
          request.response.headers
              .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
        }
        await response.stream.listen((_) {}).cancel();
        return;
      }

      if (knownPlaylist) {
        final body = await _readBoundedBody(response.stream, _maxPlaylistBytes);
        final text = utf8.decode(body, allowMalformed: true);
        if (_startsWithM3u8Magic(body)) {
          await _respondPlaylist(request.response, text, finalTarget);
          return;
        }
        _copyResponseHeaders(response, request.response);
        request.response.contentLength = body.length;
        request.response.add(body);
        return;
      }

      // Sniff prefix for extensionless #EXTM3U playlists (including PHP/text/html
      // dynamic IPTV gateways) or disguised TS segments.
      final shouldSniffPrefix = !_hasNonZeroRangeStart(range) &&
          (registered.kind == _TargetKind.tsSegment ||
              (registered.kind == _TargetKind.auto &&
                  (mime.isEmpty ||
                      mime.startsWith('text/') ||
                      mime.contains('application/text') ||
                      mime.contains('octet-stream'))));

      if (shouldSniffPrefix) {
        await _serveWithPrefixInspection(
          response,
          finalTarget,
          registered.kind,
          request.response,
        );
        return;
      }

      request.response.bufferOutput = false;
      _copyResponseHeaders(response, request.response);
      request.response.statusCode = response.statusCode;
      await _pipeMediaStream(response.stream, request.response);
    } on StateError {
      try {
        request.response.statusCode = HttpStatus.gone;
      } catch (_) {}
    } catch (error) {
      _lastUpstreamError = error;
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      _requests.remove(request);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveKcacheRequest(
    HttpRequest request,
    _RegisteredTarget registered,
  ) async {
    final cache = registered.diskCache ?? _diskCache;
    final cacheKey = registered.cacheKey ?? registered.uri.toString();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);

    if (!cache.isEnabled) {
      final (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: request.method,
        range: rangeHeader,
        ifRange: ifRange,
        allowRange: true,
      );
      if (response.statusCode == 416) {
        await response.stream.listen((_) {}).cancel();
        final (fallbackResp, _) = await _sendWithRedirects(
          registered.uri,
          method: request.method,
          allowRange: false,
        );
        _copyResponseHeaders(fallbackResp, request.response);
        request.response.statusCode = fallbackResp.statusCode;
        if (request.method == 'HEAD') {
          await fallbackResp.stream.listen((_) {}).cancel();
          return;
        }
        await _pipeMediaStream(fallbackResp.stream, request.response);
        return;
      }
      _lastUpstreamStatusCode = response.statusCode;
      _lastUpstreamHost = finalTarget.host;
      _copyResponseHeaders(response, request.response);
      request.response.statusCode = response.statusCode;
      if (request.method == 'HEAD') {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      await _pipeMediaStream(response.stream, request.response);
      return;
    }

    if (request.method == 'HEAD') {
      final meta = await cache.getMeta(cacheKey);
      if (meta?.totalLength != null) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.headers.set(
          'content-type',
          meta!.contentType ?? 'application/octet-stream',
        );
        request.response.headers.set('cache-control', 'no-store');
        request.response.contentLength = meta.totalLength!;
        return;
      }
      final (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: 'HEAD',
        allowRange: false,
      );
      _lastUpstreamStatusCode = response.statusCode;
      _lastUpstreamHost = finalTarget.host;
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final len = int.tryParse(response.headers['content-length'] ?? '');
        if (len != null && len >= 0) {
          await cache.updateMeta(
            cacheKey,
            totalLength: len,
            contentType: response.headers['content-type'],
            etag: response.headers['etag'],
          );
        }
      }
      _copyResponseHeaders(response, request.response);
      request.response.statusCode = response.statusCode;
      return;
    }

    final reqRange = _ByteRangeSpec.parse(rangeHeader);
    var meta = await cache.getMeta(cacheKey);

    if (meta?.totalLength == null) {
      await _probeAndServeKcache(
        request: request,
        registered: registered,
        cache: cache,
        cacheKey: cacheKey,
        reqRange: reqRange,
        ifRange: ifRange,
      );
      return;
    }

    await _serveKcacheWithKnownLength(
      request: request,
      registered: registered,
      cache: cache,
      cacheKey: cacheKey,
      reqRange: reqRange,
      total: meta!.totalLength!,
      contentType: meta.contentType,
      etag: meta.etag,
    );
  }

  static ({int start, int end, int? total})? _parseContentRange(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!);
    final end = int.tryParse(m.group(2)!);
    final total = m.group(3) == '*' ? null : int.tryParse(m.group(3)!);
    if (start == null || end == null || end < start) return null;
    return (start: start, end: end, total: total);
  }

  Future<void> _probeAndServeKcache({
    required HttpRequest request,
    required _RegisteredTarget registered,
    required DiskBlockCache cache,
    required String cacheKey,
    required _ByteRangeSpec? reqRange,
    required String? ifRange,
  }) async {
    String? probeRange;
    if (reqRange?.suffixLength != null) {
      probeRange = 'bytes=-${reqRange!.suffixLength!}';
    } else {
      final start = reqRange?.start ?? 0;
      final startBlock = start ~/ DiskBlockCache.blockSize;
      final endBlock = reqRange?.end != null
          ? (reqRange!.end! ~/ DiskBlockCache.blockSize)
          : startBlock;
      final alignedStart = startBlock * DiskBlockCache.blockSize;
      final alignedEnd =
          (endBlock + 1) * DiskBlockCache.blockSize - 1;
      probeRange = 'bytes=$alignedStart-$alignedEnd';
    }

    var (response, finalTarget) = await _sendWithRedirects(
      registered.uri,
      method: 'GET',
      range: probeRange,
      ifRange: ifRange,
      allowRange: true,
    );

    if (_closed || _isCancelled()) {
      await response.stream.listen((_) {}).cancel();
      request.response.statusCode = HttpStatus.gone;
      return;
    }

    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await response.stream.listen((_) {}).cancel();
      (response, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: 'GET',
        allowRange: false,
      );
      if (_closed || _isCancelled()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }
    }

    _lastUpstreamStatusCode = response.statusCode;
    _lastUpstreamHost = finalTarget.host;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen((_) {}).cancel();
      request.response.statusCode = response.statusCode;
      return;
    }
    _lastUpstreamError = null;

    final contentType = response.headers['content-type'];
    final etag = response.headers['etag'];

    if (response.statusCode == HttpStatus.ok) {
      await _ingestFullStreamToCacheAndRespond(
        upstream: response,
        downstream: request.response,
        cache: cache,
        cacheKey: cacheKey,
        reqRange: reqRange,
        contentType: contentType,
        etag: etag,
      );
      return;
    }

    // 206 Partial Content
    final cr = _parseContentRange(response.headers['content-range']);
    if (cr == null) {
      await _ingestFullStreamToCacheAndRespond(
        upstream: response,
        downstream: request.response,
        cache: cache,
        cacheKey: cacheKey,
        reqRange: reqRange,
        contentType: contentType,
        etag: etag,
      );
      return;
    }

    final chunkData = await _readBoundedBytes(response.stream);
    final total = cr.total ??
        ((cr.end - cr.start + 1 == chunkData.length &&
                chunkData.length < DiskBlockCache.blockSize)
            ? cr.end + 1
            : null);

    await _storeAlignedBlocksFromSlice(
      cache: cache,
      cacheKey: cacheKey,
      sliceStart: cr.start,
      data: chunkData,
      totalLength: total,
      contentType: contentType,
      etag: etag,
    );

    if (total == null) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set('accept-ranges', 'bytes');
      if (contentType != null && contentType.isNotEmpty) {
        request.response.headers.set('content-type', contentType);
      }
      request.response.headers.set(
        'content-range',
        'bytes ${cr.start}-${cr.start + chunkData.length - 1}/*',
      );
      request.response.contentLength = chunkData.length;
      request.response.add(chunkData);
      return;
    }

    await _serveKcacheWithKnownLength(
      request: request,
      registered: registered,
      cache: cache,
      cacheKey: cacheKey,
      reqRange: reqRange,
      total: total,
      contentType: contentType,
      etag: etag,
    );
  }

  Future<Uint8List> _readBoundedBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _storeAlignedBlocksFromSlice({
    required DiskBlockCache cache,
    required String cacheKey,
    required int sliceStart,
    required Uint8List data,
    required int? totalLength,
    String? contentType,
    String? etag,
  }) async {
    if (data.isEmpty) return;
    await cache.updateMeta(
      cacheKey,
      totalLength: totalLength,
      contentType: contentType,
      etag: etag,
    );
    var offset = 0;
    while (offset < data.length) {
      final absPos = sliceStart + offset;
      final blockIdx = absPos ~/ DiskBlockCache.blockSize;
      final blockStart = blockIdx * DiskBlockCache.blockSize;
      final inBlockOffset = absPos - blockStart;
      final remainingInBlock = DiskBlockCache.blockSize - inBlockOffset;
      final take = math.min(remainingInBlock, data.length - offset);
      final endsAtTotal =
          totalLength != null && (absPos + take) >= totalLength;
      if (inBlockOffset == 0 &&
          (take == DiskBlockCache.blockSize || endsAtTotal)) {
        await cache.writeBlock(
          cacheKey,
          blockIdx,
          Uint8List.sublistView(data, offset, offset + take),
          totalLength: totalLength,
          contentType: contentType,
          etag: etag,
        );
      }
      offset += take;
    }
  }

  Future<void> _ingestFullStreamToCacheAndRespond({
    required http.StreamedResponse upstream,
    required HttpResponse downstream,
    required DiskBlockCache cache,
    required String cacheKey,
    required _ByteRangeSpec? reqRange,
    String? contentType,
    String? etag,
  }) async {
    final headerLen = int.tryParse(upstream.headers['content-length'] ?? '');
    if (headerLen == null) {
      final allBytes = await _readBoundedBytes(upstream.stream);
      final total = allBytes.length;
      await _storeAlignedBlocksFromSlice(
        cache: cache,
        cacheKey: cacheKey,
        sliceStart: 0,
        data: allBytes,
        totalLength: total,
        contentType: contentType,
        etag: etag,
      );
      _writeSingleBufferRangeResponse(
        downstream: downstream,
        fullOrRangeData: allBytes,
        total: total,
        reqRange: reqRange,
        contentType: contentType,
      );
      return;
    }

    final total = headerLen;
    await cache.updateMeta(
      cacheKey,
      totalLength: total,
      contentType: contentType,
      etag: etag,
    );

    final int reqStart;
    final int reqEnd;
    final bool isRange;
    if (reqRange == null) {
      reqStart = 0;
      reqEnd = total - 1;
      isRange = false;
    } else if (reqRange.suffixLength != null) {
      reqStart = math.max(0, total - reqRange.suffixLength!);
      reqEnd = total - 1;
      isRange = true;
    } else {
      reqStart = reqRange.start;
      reqEnd = reqRange.end != null
          ? math.min(reqRange.end!, total - 1)
          : total - 1;
      isRange = true;
    }

    if (total > 0 && (reqStart >= total || reqStart > reqEnd)) {
      await upstream.stream.listen((_) {}).cancel();
      downstream.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      downstream.headers.set('content-range', 'bytes */$total');
      return;
    }

    downstream.bufferOutput = false;
    downstream.statusCode =
        isRange ? HttpStatus.partialContent : HttpStatus.ok;
    downstream.headers.set('accept-ranges', 'bytes');
    if (contentType != null && contentType.isNotEmpty) {
      downstream.headers.set('content-type', contentType);
    }
    downstream.headers.set('cache-control', 'no-store');
    if (isRange) {
      downstream.headers.set('content-range', 'bytes $reqStart-$reqEnd/$total');
    }
    downstream.contentLength = total == 0 ? 0 : (reqEnd - reqStart + 1);
    if (total == 0) {
      await upstream.stream.listen((_) {}).cancel();
      return;
    }

    final blockAcc = BytesBuilder(copy: false);
    var currentBlockIdx = 0;
    var streamOffset = 0;

    await for (final chunk
        in upstream.stream.timeout(const Duration(seconds: 30))) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      final chunkStart = streamOffset;
      final chunkEnd = streamOffset + chunk.length - 1;
      streamOffset += chunk.length;

      // Feed block accumulator
      var pos = 0;
      while (pos < chunk.length) {
        final needed = DiskBlockCache.blockSize - blockAcc.length;
        final take = math.min(needed, chunk.length - pos);
        blockAcc.add(
          pos == 0 && take == chunk.length
              ? chunk
              : Uint8List.sublistView(
                  Uint8List.fromList(chunk),
                  pos,
                  pos + take,
                ),
        );
        pos += take;
        if (blockAcc.length == DiskBlockCache.blockSize) {
          await cache.writeBlock(
            cacheKey,
            currentBlockIdx++,
            blockAcc.takeBytes(),
            totalLength: total,
            contentType: contentType,
            etag: etag,
          );
        }
      }

      // Forward requested slice
      if (chunkEnd >= reqStart && chunkStart <= reqEnd) {
        final s = math.max(0, reqStart - chunkStart);
        final e = math.min(chunk.length, reqEnd - chunkStart + 1);
        if (e > s) {
          downstream.add(
            s == 0 && e == chunk.length
                ? chunk
                : chunk.sublist(s, e),
          );
        }
      }
    }

    if (blockAcc.length > 0) {
      await cache.writeBlock(
        cacheKey,
        currentBlockIdx,
        blockAcc.takeBytes(),
        totalLength: total,
        contentType: contentType,
        etag: etag,
      );
    }
    await downstream.flush().timeout(const Duration(seconds: 30));
  }

  void _writeSingleBufferRangeResponse({
    required HttpResponse downstream,
    required Uint8List fullOrRangeData,
    required int total,
    required _ByteRangeSpec? reqRange,
    String? contentType,
  }) {
    if (total == 0 && reqRange == null) {
      downstream.statusCode = HttpStatus.ok;
      downstream.headers.set('accept-ranges', 'bytes');
      downstream.contentLength = 0;
      return;
    }
    final int reqStart;
    final int reqEnd;
    final bool isRange;
    if (reqRange == null) {
      reqStart = 0;
      reqEnd = total - 1;
      isRange = false;
    } else if (reqRange.suffixLength != null) {
      reqStart = math.max(0, total - reqRange.suffixLength!);
      reqEnd = total - 1;
      isRange = true;
    } else {
      reqStart = reqRange.start;
      reqEnd = reqRange.end != null
          ? math.min(reqRange.end!, total - 1)
          : total - 1;
      isRange = true;
    }
    if (reqStart >= total || reqStart > reqEnd) {
      downstream.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      downstream.headers.set('content-range', 'bytes */$total');
      return;
    }
    downstream.statusCode =
        isRange ? HttpStatus.partialContent : HttpStatus.ok;
    downstream.headers.set('accept-ranges', 'bytes');
    if (contentType != null && contentType.isNotEmpty) {
      downstream.headers.set('content-type', contentType);
    }
    downstream.headers.set('cache-control', 'no-store');
    if (isRange) {
      downstream.headers.set('content-range', 'bytes $reqStart-$reqEnd/$total');
    }
    final slice = Uint8List.sublistView(fullOrRangeData, reqStart, reqEnd + 1);
    downstream.contentLength = slice.length;
    downstream.add(slice);
  }

  Future<void> _serveKcacheWithKnownLength({
    required HttpRequest request,
    required _RegisteredTarget registered,
    required DiskBlockCache cache,
    required String cacheKey,
    required _ByteRangeSpec? reqRange,
    required int total,
    String? contentType,
    String? etag,
  }) async {
    final downstream = request.response;
    if (total == 0 && reqRange == null) {
      downstream.statusCode = HttpStatus.ok;
      downstream.headers.set('accept-ranges', 'bytes');
      if (contentType != null && contentType.isNotEmpty) {
        downstream.headers.set('content-type', contentType);
      }
      downstream.contentLength = 0;
      return;
    }

    final int reqStart;
    final int reqEnd;
    final bool isRange;
    if (reqRange == null) {
      reqStart = 0;
      reqEnd = total - 1;
      isRange = false;
    } else if (reqRange.suffixLength != null) {
      reqStart = math.max(0, total - reqRange.suffixLength!);
      reqEnd = total - 1;
      isRange = true;
    } else {
      reqStart = reqRange.start;
      reqEnd = reqRange.end != null
          ? math.min(reqRange.end!, total - 1)
          : total - 1;
      isRange = true;
    }

    if (reqStart >= total || reqStart > reqEnd) {
      downstream.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      downstream.headers.set('content-range', 'bytes */$total');
      return;
    }

    downstream.bufferOutput = false;
    downstream.statusCode =
        isRange ? HttpStatus.partialContent : HttpStatus.ok;
    downstream.headers.set('accept-ranges', 'bytes');
    downstream.headers.set(
      'content-type',
      (contentType != null && contentType.isNotEmpty)
          ? contentType
          : 'application/octet-stream',
    );
    downstream.headers.set('cache-control', 'no-store');
    if (isRange) {
      downstream.headers.set('content-range', 'bytes $reqStart-$reqEnd/$total');
    }
    downstream.contentLength = reqEnd - reqStart + 1;

    final startBlock = reqStart ~/ DiskBlockCache.blockSize;
    final endBlock = reqEnd ~/ DiskBlockCache.blockSize;
    var b = startBlock;
    while (b <= endBlock) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      final cached = await cache.readBlock(cacheKey, b);
      if (cached != null) {
        final blockBase = b * DiskBlockCache.blockSize;
        final s = math.max(0, reqStart - blockBase);
        final e = math.min(cached.length, reqEnd - blockBase + 1);
        if (e > s) {
          downstream.add(Uint8List.sublistView(cached, s, e));
        }
        b++;
        continue;
      }

      // Group contiguous uncached blocks (capped at 16 blocks = 4 MiB per window).
      var runEnd = b;
      final maxRunEnd = math.min(endBlock, b + 15);
      while (runEnd + 1 <= maxRunEnd &&
          !(await cache.hasBlock(cacheKey, runEnd + 1))) {
        runEnd++;
      }

      final fetchStart = b * DiskBlockCache.blockSize;
      final fetchEnd = math.min(
        (runEnd + 1) * DiskBlockCache.blockSize - 1,
        total - 1,
      );

      var (resp, finalTarget) = await _sendWithRedirects(
        registered.uri,
        method: 'GET',
        range: 'bytes=$fetchStart-$fetchEnd',
        allowRange: true,
      );

      if (resp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await resp.stream.listen((_) {}).cancel();
        (resp, finalTarget) = await _sendWithRedirects(
          registered.uri,
          method: 'GET',
          allowRange: false,
        );
      }

      _lastUpstreamStatusCode = resp.statusCode;
      _lastUpstreamHost = finalTarget.host;
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.stream.listen((_) {}).cancel();
        throw HttpException('Upstream error ${resp.statusCode}');
      }

      final respContentType = resp.headers['content-type'] ?? contentType;
      final respEtag = resp.headers['etag'] ?? etag;

      if (resp.statusCode == HttpStatus.ok) {
        // Server sent full body from offset 0 without range support.
        final blockAcc = BytesBuilder(copy: false);
        var blkIdx = 0;
        var streamOff = 0;
        await for (final chunk
            in resp.stream.timeout(const Duration(seconds: 30))) {
          if (_closed || _isCancelled()) throw StateError('cancelled');
          final cStart = streamOff;
          final cEnd = streamOff + chunk.length - 1;
          streamOff += chunk.length;

          var pos = 0;
          while (pos < chunk.length) {
            final need = DiskBlockCache.blockSize - blockAcc.length;
            final take = math.min(need, chunk.length - pos);
            blockAcc.add(
              pos == 0 && take == chunk.length
                  ? chunk
                  : Uint8List.sublistView(
                      Uint8List.fromList(chunk),
                      pos,
                      pos + take,
                    ),
            );
            pos += take;
            if (blockAcc.length == DiskBlockCache.blockSize) {
              await cache.writeBlock(
                cacheKey,
                blkIdx++,
                blockAcc.takeBytes(),
                totalLength: total,
                contentType: respContentType,
                etag: respEtag,
              );
            }
          }

          final wantStart = math.max(reqStart, fetchStart);
          if (cEnd >= wantStart && cStart <= reqEnd) {
            final s = math.max(0, wantStart - cStart);
            final e = math.min(chunk.length, reqEnd - cStart + 1);
            if (e > s) {
              downstream.add(s == 0 && e == chunk.length ? chunk : chunk.sublist(s, e));
            }
          }
        }
        if (blockAcc.length > 0) {
          await cache.writeBlock(
            cacheKey,
            blkIdx,
            blockAcc.takeBytes(),
            totalLength: total,
            contentType: respContentType,
            etag: respEtag,
          );
        }
        break;
      }

      // 206 Partial Content for [fetchStart .. fetchEnd]
      final cr = _parseContentRange(resp.headers['content-range']);
      final actualStart = cr?.start ?? fetchStart;
      final blockAcc = BytesBuilder(copy: false);
      var currentBlk = actualStart ~/ DiskBlockCache.blockSize;
      var inBlockAlign = actualStart % DiskBlockCache.blockSize;
      var streamPos = actualStart;

      await for (final chunk
          in resp.stream.timeout(const Duration(seconds: 30))) {
        if (_closed || _isCancelled()) throw StateError('cancelled');
        final cStart = streamPos;
        final cEnd = streamPos + chunk.length - 1;
        streamPos += chunk.length;

        var pos = 0;
        if (inBlockAlign > 0) {
          final skipToAlign =
              math.min(DiskBlockCache.blockSize - inBlockAlign, chunk.length);
          pos += skipToAlign;
          inBlockAlign = (inBlockAlign + skipToAlign) % DiskBlockCache.blockSize;
          if (inBlockAlign == 0) currentBlk++;
        }
        while (pos < chunk.length) {
          final need = DiskBlockCache.blockSize - blockAcc.length;
          final take = math.min(need, chunk.length - pos);
          blockAcc.add(
            pos == 0 && take == chunk.length
                ? chunk
                : Uint8List.sublistView(
                    Uint8List.fromList(chunk),
                    pos,
                    pos + take,
                  ),
          );
          pos += take;
          final absEndAfter = cStart + pos;
          if (blockAcc.length == DiskBlockCache.blockSize ||
              absEndAfter >= total) {
            await cache.writeBlock(
              cacheKey,
              currentBlk++,
              blockAcc.takeBytes(),
              totalLength: total,
              contentType: respContentType,
              etag: respEtag,
            );
          }
        }

        final wantStart = math.max(reqStart, fetchStart);
        final wantEnd = math.min(reqEnd, fetchEnd);
        if (cEnd >= wantStart && cStart <= wantEnd) {
          final s = math.max(0, wantStart - cStart);
          final e = math.min(chunk.length, wantEnd - cStart + 1);
          if (e > s) {
            downstream.add(s == 0 && e == chunk.length ? chunk : chunk.sublist(s, e));
          }
        }
      }

      if (blockAcc.length > 0 && streamPos >= total) {
        await cache.writeBlock(
          cacheKey,
          currentBlk,
          blockAcc.takeBytes(),
          totalLength: total,
          contentType: respContentType,
          etag: respEtag,
        );
      }

      b = runEnd + 1;
    }

    await downstream.flush().timeout(const Duration(seconds: 30));
  }

  void _copyResponseHeaders(
      http.StreamedResponse upstream, HttpResponse downstream) {
    downstream.statusCode = upstream.statusCode;
    final encoding = (upstream.headers['content-encoding'] ?? '').trim().toLowerCase();
    final isCompressed = encoding.isNotEmpty && encoding != 'identity';
    for (final key in const [
      'content-type',
      'content-length',
      'content-range',
      'accept-ranges',
      'etag',
      'last-modified',
    ]) {
      if (key == 'content-length' && isCompressed) continue;
      final value = upstream.headers[key];
      if (value != null && value.isNotEmpty) {
        downstream.headers.set(key, value);
      }
    }
    downstream.headers.set('cache-control', 'no-store');
  }

  Future<Uint8List> _readBoundedBody(
      Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (_closed || _isCancelled()) throw StateError('cancelled');
      if (builder.length + chunk.length > maxBytes) {
        throw const FormatException('媒体播放列表体积超出安全上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _respondPlaylist(
      HttpResponse downstream, String playlistText, Uri playlistOrigin) async {
    final rewritten = _rewritePlaylist(playlistText, playlistOrigin);
    final encoded = utf8.encode(rewritten);
    downstream.statusCode = HttpStatus.ok;
    downstream.headers.removeAll('content-range');
    downstream.headers
        .set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl');
    downstream.headers.set('cache-control', 'no-store');
    downstream.contentLength = encoded.length;
    downstream.add(encoded);
  }

  Future<void> _serveWithPrefixInspection(
    http.StreamedResponse upstream,
    Uri finalTarget,
    _TargetKind kind,
    HttpResponse downstream,
  ) async {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;
    var phase = 0; // 0: sniffing prefix, 1: playlist accumulation, 2: binary streaming
    var pendingBytes = 0;
    final prefixBuilder = BytesBuilder(copy: false);
    final playlistBuilder = BytesBuilder(copy: false);

    Future<void> finish([Object? error, StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      final sub = subscription;
      if (sub != null) {
        _upstreams.remove(sub);
        try {
          await sub.cancel();
        } catch (_) {}
      }
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(error, stackTrace);
        } else {
          done.complete();
        }
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 30), () {
        unawaited(finish(TimeoutException('upstream media idle')));
      });
    }

    void beginBinaryStream(Uint8List prefix) {
      phase = 2;
      downstream.bufferOutput = false;
      final skip =
          kind == _TargetKind.tsSegment ? findDisguisedTsOffset(prefix) : 0;
      _copyResponseHeaders(upstream, downstream);
      if (skip > 0) {
        downstream.statusCode = HttpStatus.ok;
        downstream.headers.removeAll('content-range');
        downstream.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
        final rawLen = int.tryParse(upstream.headers['content-length'] ?? '');
        if (rawLen != null && rawLen >= skip) {
          downstream.contentLength = rawLen - skip;
        } else {
          downstream.headers.removeAll(HttpHeaders.contentLengthHeader);
        }
      }
      final initialSlice = skip > 0 ? prefix.sublist(skip) : prefix;
      if (initialSlice.isNotEmpty) {
        downstream.add(initialSlice);
        pendingBytes += initialSlice.length;
      }
    }

    unawaited(downstream.done.then((_) => finish(), onError: (_) => finish()));
    resetIdleTimer();
    subscription = upstream.stream.listen(
      (chunk) {
        if (finished || _closed || _isCancelled()) {
          unawaited(finish(StateError('cancelled')));
          return;
        }
        resetIdleTimer();
        try {
          if (phase == 0) {
            prefixBuilder.add(chunk);
            final currentBytes = prefixBuilder.toBytes();
            if (_startsWithM3u8Magic(currentBytes) && currentBytes.length >= 7) {
              final taken = prefixBuilder.takeBytes();
              if (taken.length > _maxPlaylistBytes) {
                unawaited(
                  finish(const FormatException('媒体播放列表体积超出安全上限')),
                );
                return;
              }
              phase = 1;
              playlistBuilder.add(taken);
              return;
            }
            if (kind == _TargetKind.auto && !_couldBeM3u8Prefix(currentBytes)) {
              beginBinaryStream(prefixBuilder.takeBytes());
              return;
            }
            if (prefixBuilder.length >= _sniffPrefixBytes) {
              final prefix = prefixBuilder.takeBytes();
              if (_startsWithM3u8Magic(prefix)) {
                if (prefix.length > _maxPlaylistBytes) {
                  unawaited(
                    finish(const FormatException('媒体播放列表体积超出安全上限')),
                  );
                  return;
                }
                phase = 1;
                playlistBuilder.add(prefix);
                return;
              }
              beginBinaryStream(prefix);
            }
            return;
          }
          if (phase == 1) {
            if (playlistBuilder.length + chunk.length > _maxPlaylistBytes) {
              unawaited(
                finish(const FormatException('媒体播放列表体积超出安全上限')),
              );
              return;
            }
            playlistBuilder.add(chunk);
            return;
          }
          downstream.add(chunk);
          pendingBytes += chunk.length;
          final flushThreshold =
              _isLive ? _liveFlushThresholdBytes : _flushThresholdBytes;
          if (pendingBytes >= flushThreshold) {
            pendingBytes = 0;
            subscription?.pause(
              downstream
                  .flush()
                  .timeout(const Duration(seconds: 30))
                  .catchError((_) => finish()),
            );
          }
        } catch (e, st) {
          unawaited(finish(e, st));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finish(error, stackTrace));
      },
      onDone: () async {
        if (finished) return;
        try {
          if (phase == 0) {
            final prefix = prefixBuilder.takeBytes();
            if (_startsWithM3u8Magic(prefix)) {
              final text = utf8.decode(prefix, allowMalformed: true);
              await _respondPlaylist(downstream, text, finalTarget);
            } else {
              beginBinaryStream(prefix);
            }
          } else if (phase == 1) {
            final text = utf8.decode(
              playlistBuilder.takeBytes(),
              allowMalformed: true,
            );
            await _respondPlaylist(downstream, text, finalTarget);
          }
          await finish();
        } catch (e, st) {
          await finish(e, st);
        }
      },
      cancelOnError: true,
    );
    _upstreams.add(subscription);
    await done.future;
    if (!_closed && !_isCancelled() && phase == 2 && pendingBytes > 0) {
      try {
        await downstream.flush().timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  Future<void> _pipeMediaStream(
    Stream<List<int>> source,
    HttpResponse sink,
  ) async {
    final done = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;
    var pendingBytes = 0;

    Future<void> finish([Object? error, StackTrace? stackTrace]) async {
      if (finished) return;
      finished = true;
      idleTimer?.cancel();
      final sub = subscription;
      if (sub != null) {
        _upstreams.remove(sub);
        try {
          await sub.cancel();
        } catch (_) {}
      }
      if (!done.isCompleted) {
        if (error != null) {
          done.completeError(error, stackTrace);
        } else {
          done.complete();
        }
      }
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(const Duration(seconds: 30), () {
        unawaited(finish(TimeoutException('upstream media idle')));
      });
    }

    unawaited(sink.done.then((_) => finish(), onError: (_) => finish()));
    resetIdleTimer();
    subscription = source.listen(
      (chunk) {
        if (finished || _closed || _isCancelled()) {
          unawaited(finish());
          return;
        }
        resetIdleTimer();
        try {
          sink.add(chunk);
        } catch (_) {
          unawaited(finish());
          return;
        }
        pendingBytes += chunk.length;
        final flushThreshold =
            _isLive ? _liveFlushThresholdBytes : _flushThresholdBytes;
        if (pendingBytes >= flushThreshold) {
          pendingBytes = 0;
          subscription?.pause(
            sink
                .flush()
                .timeout(const Duration(seconds: 30))
                .catchError((_) => finish()),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(finish(error, stackTrace));
      },
      onDone: () {
        unawaited(finish());
      },
      cancelOnError: true,
    );
    _upstreams.add(subscription);
    await done.future;
    if (!_closed && !_isCancelled() && pendingBytes > 0) {
      try {
        await sink.flush().timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
  }

  static String stripVodPlaylistAds(
    String text,
    Uri origin, {
    List<String> adPatterns = const [],
  }) {
    final rawLines = text.split('\n');
    final lines = [
      for (final raw in rawLines)
        raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw,
    ];
    var hasEndList = false;
    var isVodType = false;
    var hasDiscontinuity = false;
    var isMaster = false;

    for (final line in lines) {
      final t = line.trim();
      final upper = t.toUpperCase();
      if (upper == '#EXT-X-ENDLIST') {
        hasEndList = true;
      } else if (upper.startsWith('#EXT-X-PLAYLIST-TYPE:') &&
          upper.contains('VOD')) {
        isVodType = true;
      } else if (upper == '#EXT-X-DISCONTINUITY') {
        hasDiscontinuity = true;
      } else if (upper.startsWith('#EXT-X-STREAM-INF')) {
        isMaster = true;
      }
    }

    if (isMaster || !hasDiscontinuity || (!hasEndList && !isVodType)) {
      return text;
    }

    // Parse header, discontinuity blocks of segments, and footer.
    final headerLines = <String>[];
    final footerLines = <String>[];
    final blocks = <List<({
      List<String> tags,
      String uriLine,
      Uri? resolvedUri,
      double duration,
      String? keyTag,
      String? mapTag,
    })>>[];
    var currentBlock = <({
      List<String> tags,
      String uriLine,
      Uri? resolvedUri,
      double duration,
      String? keyTag,
      String? mapTag,
    })>[];
    var pendingTags = <String>[];
    double pendingDuration = 0.0;
    var seenFirstSegment = false;
    String? activeKey;
    String? activeMap;

    for (final line in lines) {
      final t = line.trim();
      final upper = t.toUpperCase();
      if (upper == '#EXT-X-ENDLIST') {
        footerLines.add(line);
        continue;
      }
      if (!seenFirstSegment &&
          t.startsWith('#') &&
          !upper.startsWith('#EXTINF:') &&
          !upper.startsWith('#EXT-X-KEY:') &&
          !upper.startsWith('#EXT-X-MAP:') &&
          !upper.startsWith('#EXT-X-BYTERANGE:') &&
          upper != '#EXT-X-DISCONTINUITY') {
        headerLines.add(line);
        continue;
      }
      if (upper == '#EXT-X-DISCONTINUITY') {
        if (currentBlock.isNotEmpty) {
          blocks.add(currentBlock);
          currentBlock = [];
        }
        seenFirstSegment = true;
        continue;
      }
      if (t.isEmpty) continue;
      if (t.startsWith('#')) {
        seenFirstSegment = true;
        if (upper.startsWith('#EXTINF:')) {
          final rawDur = t.substring(8).split(',').first.trim();
          pendingDuration = double.tryParse(rawDur) ?? 0.0;
        } else if (upper.startsWith('#EXT-X-KEY:')) {
          activeKey = line;
        } else if (upper.startsWith('#EXT-X-MAP:')) {
          activeMap = line;
        }
        pendingTags.add(line);
        continue;
      }

      seenFirstSegment = true;
      Uri? resolved;
      try {
        resolved = origin.resolve(t);
      } catch (_) {}
      currentBlock.add((
        tags: pendingTags,
        uriLine: line,
        resolvedUri: resolved,
        duration: pendingDuration,
        keyTag: activeKey,
        mapTag: activeMap,
      ));
      pendingTags = <String>[];
      pendingDuration = 0.0;
    }
    if (currentBlock.isNotEmpty) {
      blocks.add(currentBlock);
    }

    if (blocks.length < 2) return text;

    String dirPrefixOf(Uri uri) {
      final path = uri.path;
      final slash = path.lastIndexOf('/');
      return slash <= 0 ? '/' : path.substring(0, slash + 1).toLowerCase();
    }

    final hostDurations = <String, double>{};
    final dirDurations = <String, double>{};
    var totalDuration = 0.0;
    for (final blk in blocks) {
      for (final seg in blk) {
        totalDuration += seg.duration;
        final uri = seg.resolvedUri;
        if (uri != null && uri.host.isNotEmpty) {
          final host = uri.host.toLowerCase();
          hostDurations[host] = (hostDurations[host] ?? 0) + seg.duration;
          final dirKey = '$host|${dirPrefixOf(uri)}';
          dirDurations[dirKey] = (dirDurations[dirKey] ?? 0) + seg.duration;
        }
      }
    }
    if (totalDuration <= 0) return text;

    String dominantHost = '';
    var maxHostDur = -1.0;
    hostDurations.forEach((host, dur) {
      if (dur > maxHostDur) {
        maxHostDur = dur;
        dominantHost = host;
      }
    });

    String dominantDirKey = '';
    var maxDirDur = -1.0;
    dirDurations.forEach((dk, dur) {
      if (dur > maxDirDur) {
        maxDirDur = dur;
        dominantDirKey = dk;
      }
    });

    final adHeuristicRegex = RegExp(
      r'(?:^|/)(?:ad|ads|advert|promo|guanggao|sponsor|commercial)(?:/|$)|(?:^|/)(?:adjump|ad_?\d+|adv\d+|guanggao\d*)[^/]*\.(?:ts|m4s|mp4|png|jpg|jpeg)(?:$|[?#])',
      caseSensitive: false,
    );

    bool matchesAdRule(Uri uri) {
      final full = uri.toString().toLowerCase();
      final host = uri.host.toLowerCase();
      if (adHeuristicRegex.hasMatch(uri.path)) return true;
      for (final raw in adPatterns) {
        final pat = raw.trim().toLowerCase();
        if (pat.isEmpty) continue;
        if (!pat.contains('/') && !pat.contains('?')) {
          final clean = pat.startsWith('*.')
              ? pat.substring(2)
              : (pat.startsWith('.') ? pat.substring(1) : pat);
          if (clean.isNotEmpty &&
              (host == clean || host.endsWith('.$clean'))) {
            return true;
          }
        } else if (full.contains(pat)) {
          return true;
        }
      }
      return false;
    }

    final stripFlags = List<bool>.filled(blocks.length, false);
    var removedDuration = 0.0;

    for (var i = 0; i < blocks.length; i++) {
      final blk = blocks[i];
      if (blk.isEmpty || blk.length > 20) continue;
      final blkDur = blk.fold<double>(0.0, (sum, s) => sum + s.duration);
      if (blkDur <= 0 || blkDur > 60.0) continue;
      if (blk.any((s) => s.duration > 60.0)) continue;

      final hosts = blk
          .map((s) => s.resolvedUri?.host.toLowerCase() ?? '')
          .where((h) => h.isNotEmpty)
          .toSet();
      final dirKeys = blk
          .map((s) => s.resolvedUri == null
              ? ''
              : '${s.resolvedUri!.host.toLowerCase()}|${dirPrefixOf(s.resolvedUri!)}')
          .where((k) => k.isNotEmpty)
          .toSet();

      final crossDomainAnomaly = dominantHost.isNotEmpty &&
          hosts.isNotEmpty &&
          !hosts.contains(dominantHost);
      final hitsAdSignature = blk.any(
        (s) => s.resolvedUri != null && matchesAdRule(s.resolvedUri!),
      );
      final isSandwichedDirJump = i > 0 &&
          i + 1 < blocks.length &&
          dominantDirKey.isNotEmpty &&
          dirKeys.isNotEmpty &&
          !dirKeys.contains(dominantDirKey) &&
          blocks[i - 1].any((s) =>
              s.resolvedUri != null &&
              '${s.resolvedUri!.host.toLowerCase()}|${dirPrefixOf(s.resolvedUri!)}' ==
                  dominantDirKey) &&
          blocks[i + 1].any((s) =>
              s.resolvedUri != null &&
              '${s.resolvedUri!.host.toLowerCase()}|${dirPrefixOf(s.resolvedUri!)}' ==
                  dominantDirKey);

      if (crossDomainAnomaly || hitsAdSignature || isSandwichedDirJump) {
        if (removedDuration + blkDur <= totalDuration * 0.40 + 1e-6) {
          stripFlags[i] = true;
          removedDuration += blkDur;
        }
      }
    }

    if (!stripFlags.any((f) => f)) return text;

    final out = <String>[...headerLines];
    var emittedAnyKeptBlock = false;
    var strippedSinceLastKept = false;
    String? lastEmittedKey;
    String? lastEmittedMap;

    for (var i = 0; i < blocks.length; i++) {
      if (stripFlags[i]) {
        strippedSinceLastKept = true;
        continue;
      }
      final blk = blocks[i];
      if (emittedAnyKeptBlock) {
        out.add('#EXT-X-DISCONTINUITY');
      }
      for (var sIdx = 0; sIdx < blk.length; sIdx++) {
        final seg = blk[sIdx];
        final hasOwnKey = seg.tags
            .any((t) => t.trim().toUpperCase().startsWith('#EXT-X-KEY:'));
        final hasOwnMap = seg.tags
            .any((t) => t.trim().toUpperCase().startsWith('#EXT-X-MAP:'));
        if (sIdx == 0 && strippedSinceLastKept) {
          if (!hasOwnKey && lastEmittedKey != null) {
            out.add(lastEmittedKey);
          }
          if (!hasOwnMap && lastEmittedMap != null) {
            out.add(lastEmittedMap);
          }
        }
        for (final tag in seg.tags) {
          final tu = tag.trim().toUpperCase();
          if (tu.startsWith('#EXT-X-KEY:')) lastEmittedKey = tag;
          if (tu.startsWith('#EXT-X-MAP:')) lastEmittedMap = tag;
          out.add(tag);
        }
        out.add(seg.uriLine);
      }
      emittedAnyKeptBlock = true;
      strippedSinceLastKept = false;
    }
    out.addAll(footerLines);
    return out.join('\n');
  }

  String _rewritePlaylist(String text, Uri origin) {
    final cleanedText = (_stripHlsAds && !_isLive)
        ? stripVodPlaylistAds(text, origin, adPatterns: _adPatterns)
        : text;
    var encrypted = false;
    var hasInitMap = false;
    var expectVariant = false;

    String rewriteUri(String rawUri, _TargetKind kind) {
      final cleaned = rawUri.trim();
      if (cleaned.isEmpty || cleaned.startsWith('data:')) return rawUri;
      final resolved = origin.resolve(cleaned);
      if (!_canRegisterTarget(resolved)) {
        throw const FormatException('播放列表包含不受信任的分片地址');
      }
      return _register(resolved, kind).toString();
    }

    final out = <String>[];
    for (final rawLine in cleanedText.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
          expectVariant = true;
          out.add(line);
          continue;
        }
        if (trimmed.startsWith('#EXT-X-KEY:')) {
          final methodMatch =
              RegExp(r'METHOD=([^,\s]+)', caseSensitive: false).firstMatch(trimmed);
          final method = methodMatch?.group(1)?.trim().toUpperCase() ?? 'NONE';
          encrypted = method != 'NONE';
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MAP:')) {
          hasInitMap = true;
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.raw)}"',
          ));
          continue;
        }
        if (trimmed.startsWith('#EXT-X-MEDIA:') ||
            trimmed.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
          out.add(line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) => 'URI="${rewriteUri(m[1]!, _TargetKind.playlist)}"',
          ));
          continue;
        }
        out.add(line);
        continue;
      }

      final resolved = origin.resolve(trimmed);
      final looksPlaylist = expectVariant ||
          resolved.path.toLowerCase().endsWith('.m3u8');
      expectVariant = false;
      final kind = looksPlaylist
          ? _TargetKind.playlist
          : ((!encrypted && !hasInitMap)
              ? _TargetKind.tsSegment
              : _TargetKind.raw);
      out.add(rewriteUri(trimmed, kind));
    }
    return out.join('\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    final cachesToFlush = <DiskBlockCache>{
      for (final t in _targets.values)
        if (t.kind == _TargetKind.kcache) t.diskCache ?? _diskCache,
    };
    _headers.clear();
    _cookieJar.clear();
    _targets.clear();
    _paths.clear();
    final activeUpstreams = _upstreams.toList();
    _upstreams.clear();
    for (final sub in activeUpstreams) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    for (final c in cachesToFlush) {
      try {
        await c.flush();
      } catch (_) {}
    }
    if (_ownsClient) {
      _client.close();
      _directOnlyClient?.close();
      _directOnlyClient = null;
    }
    await _server.close(force: true);
  }
}

/// Owns the active episode's local `127.0.0.1` gateway lease in `PlayerScreen`.
class PlayerLocalMediaSession {
  LocalMediaLease? _current;
  LocalMediaLease? get current => _current;

  bool owns(LocalMediaLease? lease) =>
      lease != null && identical(lease, _current);

  void adopt(LocalMediaLease? lease) => _current = lease;

  LocalMediaLease? detach() {
    final previous = _current;
    _current = null;
    return previous;
  }

  Future<void> releaseUnless(LocalMediaLease? keep) async {
    if (!owns(keep)) await detach()?.close();
  }

  Future<void> discard(LocalMediaLease? lease) async {
    if (lease != null && !owns(lease)) await lease.close();
  }
}

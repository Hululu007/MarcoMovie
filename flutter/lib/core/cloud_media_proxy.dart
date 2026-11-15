import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'quark_account.dart';
import 'resilient_http_client.dart';

enum CloudMediaProvider { uc, quark, baidu, ali }

/// A player-owned capability for one cloud file and its quality variants.
/// Account headers stay here, scoped to the selected provider's HTTPS hosts.
/// Large byte-range streams automatically use 6-worker × 1 MiB concurrent
/// Range prefetching bounded by a hard 24 MiB memory ceiling.
class CloudMediaLease {
  CloudMediaLease._(
    this._server,
    this._client,
    Uri target,
    this._provider,
    this._headers,
    this._isCancelled,
    this._isCurrent,
    this._capability,
    DateTime Function() clock,
    this._chunkWorkers,
    this._chunkSize,
  )   : _clock = clock,
        _created = clock() {
    urlFor(target);
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sweep());
  }

  static const int _maxConcurrentRequests = 24;
  static const int _flushThresholdBytes = 4 * 1024 * 1024;
  static const int defaultChunkWorkers = 6;
  static const int defaultChunkSize = 1024 * 1024;
  static const int maxBufferedBytes = 24 * 1024 * 1024;

  static http.Client createDefaultMediaClient() => ResilientHttpClient(
        autoUncompress: false,
        maxConnectionsPerHost: 12,
        connectionTimeout: const Duration(seconds: 20),
        idleTimeout: const Duration(seconds: 30),
      );

  final HttpServer _server;
  final http.Client _client;
  final CloudMediaProvider _provider;
  final _targets = <String, Uri>{};
  final _paths = <Uri, String>{};
  final Map<String, String> _headers;
  final bool Function() _isCancelled;
  final Future<bool> Function() _isCurrent;
  final String _capability;
  final int _chunkWorkers;
  final int _chunkSize;
  final _requests = <HttpRequest>{};
  final _upstreams = <StreamSubscription<List<int>>>{};
  final _windowAborts = <Completer<void>>{};
  final DateTime Function() _clock;
  final DateTime _created;
  Timer? _timer;
  Completer<void>? _spaceSignal;
  int _reservedBytes = 0;
  int _peakReservedBytes = 0;
  bool _closed = false;
  bool _checking = false;

  int get bufferedBytes => _reservedBytes;
  int get peakBufferedBytes => _peakReservedBytes;

  Uri get url =>
      Uri.parse('http://127.0.0.1:${_server.port}/$_capability/media');

  static bool isTrustedQuarkMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (uri.host == 'quark.cn' || uri.host.endsWith('.quark.cn'));

  static bool isTrustedBaiduAccountMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (uri.host == 'baidu.com' || uri.host.endsWith('.baidu.com'));

  static bool isTrustedBaiduMedia(Uri uri) =>
      isTrustedBaiduAccountMedia(uri) ||
      (uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          (!uri.hasPort || uri.port == 443) &&
          (uri.host == 'baidupcs.com' || uri.host.endsWith('.baidupcs.com')));

  static bool isSafeBaiduRedirectTarget(Uri uri) =>
      isTrustedBaiduAccountMedia(uri) ||
      (uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          uri.host.isNotEmpty &&
          uri.host.contains('.') &&
          InternetAddress.tryParse(uri.host) == null &&
          !uri.host.endsWith('.localhost'));

  static bool isTrustedAliMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      uri.host.isNotEmpty &&
      uri.host.contains('.') &&
      InternetAddress.tryParse(uri.host) == null &&
      !uri.host.endsWith('.localhost');

  bool _trusted(Uri uri) => switch (_provider) {
        CloudMediaProvider.quark => isTrustedQuarkMedia(uri),
        CloudMediaProvider.baidu => isTrustedBaiduMedia(uri),
        CloudMediaProvider.uc => isTrustedUcMedia(uri),
        CloudMediaProvider.ali => isTrustedAliMedia(uri),
      };

  /// Only provider API responses or a provider playlist can register a target.
  /// The incoming HTTP request never supplies an upstream URL.
  Uri urlFor(Uri target) {
    if (_closed || !_trusted(target) || _targets.length >= 32768) {
      throw const FormatException('网盘媒体地址无效或播放会话已结束');
    }
    final path = _paths.putIfAbsent(target, () {
      final suffix = _targets.isEmpty ? 'media' : 'media-${_targets.length}';
      final path = '/$_capability/$suffix';
      _targets[path] = target;
      return path;
    });
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  static bool isTrustedUcMedia(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      (uri.host == 'uc.cn' ||
          uri.host.endsWith('.uc.cn') ||
          uri.host == 'ucweb.com' ||
          uri.host.endsWith('.ucweb.com'));

  static Future<CloudMediaLease> open({
    required Uri target,
    required Map<String, String> headers,
    required bool Function() isCancelled,
    required Future<bool> Function() isCurrent,
    CloudMediaProvider provider = CloudMediaProvider.uc,
    DateTime Function()? clock,
    http.Client? client,
    int? chunkWorkers,
    int chunkSize = defaultChunkSize,
  }) async {
    final validTarget = switch (provider) {
      CloudMediaProvider.quark => isTrustedQuarkMedia(target),
      CloudMediaProvider.baidu => isTrustedBaiduMedia(target),
      CloudMediaProvider.uc => isTrustedUcMedia(target),
      CloudMediaProvider.ali => isTrustedAliMedia(target),
    };
    if (!validTarget) {
      client?.close();
      throw const FormatException('网盘返回的媒体域名无法安全携带账号会话');
    }
    if (isCancelled() || !await isCurrent()) {
      client?.close();
      throw const FormatException('播放已取消或网盘账号已切换');
    }
    final resolvedWorkers = (chunkWorkers ??
            (client == null || client is ResilientHttpClient
                ? defaultChunkWorkers
                : 0))
        .clamp(0, 6);
    final resolvedChunkSize = chunkSize.clamp(64 * 1024, 2 * 1024 * 1024);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..autoCompress = false;
    final token = base64Url
        .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    return CloudMediaLease._(
      server,
      client ?? createDefaultMediaClient(),
      target,
      provider,
      Map.of(headers),
      isCancelled,
      isCurrent,
      token,
      clock ?? DateTime.now,
      resolvedWorkers,
      resolvedChunkSize,
    );
  }

  void _reserveBytes(int bytes) {
    _reservedBytes += bytes;
    if (_reservedBytes > _peakReservedBytes) {
      _peakReservedBytes = _reservedBytes;
    }
  }

  void _releaseBytes(int bytes) {
    _reservedBytes = max(0, _reservedBytes - bytes);
    final signal = _spaceSignal;
    if (signal != null && !signal.isCompleted) {
      _spaceSignal = null;
      signal.complete();
    }
  }

  Future<void> _waitForBufferSpace(int bytes, Future<void> abort) async {
    while (!_closed &&
        !_isCancelled() &&
        _reservedBytes + bytes > maxBufferedBytes) {
      final signal = _spaceSignal ??= Completer<void>();
      await Future.any([
        signal.future,
        abort.then((_) => throw const FormatException('chunk window aborted')),
      ]);
    }
  }

  Future<void> _sweep() async {
    if (_checking || _closed) return;
    _checking = true;
    try {
      if (_isCancelled() ||
          // The player owns this lease through pauses and releases it on exit
          // or episode changes. Inactivity does not imply playback has ended.
          _clock().difference(_created) >= const Duration(hours: 12) ||
          !await _isCurrent()) {
        await close();
      }
    } catch (_) {
      await close();
    } finally {
      _checking = false;
    }
  }

  static (int, int, int)? _parseContentRange(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(raw.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null ||
        end == null ||
        total == null ||
        start > end ||
        end >= total) {
      return null;
    }
    return (start, end, total);
  }

  Future<void> _serve(HttpRequest request) async {
    final target = _targets[request.uri.path];
    if (_closed ||
        target == null ||
        request.uri.hasQuery ||
        !const ['GET', 'HEAD'].contains(request.method)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (_requests.length >= _maxConcurrentRequests) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
      return;
    }
    _requests.add(request);
    try {
      if (_isCancelled() || !await _isCurrent()) {
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      final upstream = http.Request(request.method, target)
        ..followRedirects = false;
      final includeCookie = (_provider != CloudMediaProvider.baidu &&
              _provider != CloudMediaProvider.ali) ||
          (_provider == CloudMediaProvider.baidu &&
              isTrustedBaiduAccountMedia(target));
      _copyHeaders(upstream.headers, includeCookie: includeCookie);
      upstream.headers['Accept-Encoding'] = 'identity';
      final range = request.headers.value('range');
      final isPlaylistTarget = target.path.toLowerCase().endsWith('.m3u8') ||
          (!target.path.toLowerCase().endsWith('.ts') &&
              target.query.toLowerCase().contains('m3u8'));
      int? chunkReqStart;
      int? chunkReqEnd;
      var useChunkedRange = false;
      if (range != null) {
        if (!RegExp(r'^bytes=\d*-\d*$').hasMatch(range) || range == 'bytes=-') {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        if (!isPlaylistTarget) {
          final m = _chunkWorkers > 1 && request.method == 'GET'
              ? RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)
              : null;
          if (m != null) {
            final parsedStart = int.tryParse(m.group(1)!);
            final endStr = m.group(2)!;
            final parsedEnd = endStr.isEmpty ? null : int.tryParse(endStr);
            if (parsedStart != null &&
                (parsedEnd == null ||
                    (parsedEnd >= parsedStart &&
                        parsedEnd - parsedStart >= _chunkSize))) {
              chunkReqStart = parsedStart;
              chunkReqEnd = parsedEnd;
              useChunkedRange = true;
              final firstProbeEnd = parsedEnd != null
                  ? min(parsedStart + _chunkSize - 1, parsedEnd)
                  : parsedStart + _chunkSize - 1;
              upstream.headers['Range'] = 'bytes=$parsedStart-$firstProbeEnd';
            } else {
              upstream.headers['Range'] = range;
            }
          } else {
            upstream.headers['Range'] = range;
          }
        }
      }
      final (response, finalTarget) = await _send(upstream);
      if (_closed || _isCancelled() || !await _isCurrent()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      // UC keeps its existing no-redirect policy. Quark/Baidu/Ali redirects are
      // followed only after checking every destination against provider scope.
      if (!const [200, 206, 416].contains(response.statusCode)) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.badGateway;
        return;
      }
      final mime = response.headers['content-type'] ?? '';
      final encoding =
          response.headers['content-encoding']?.toLowerCase() ?? '';
      if ((encoding.isNotEmpty && encoding != 'identity') ||
          mime.contains('text/html') ||
          mime.contains('application/json')) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.badGateway;
        return;
      }
      if (useChunkedRange &&
          chunkReqStart != null &&
          response.statusCode == HttpStatus.partialContent &&
          !mime.toLowerCase().contains('mpegurl') &&
          !finalTarget.path.toLowerCase().endsWith('.m3u8')) {
        final cr = _parseContentRange(response.headers['content-range']);
        if (cr != null &&
            cr.$1 == chunkReqStart &&
            cr.$2 >= chunkReqStart &&
            cr.$3 > cr.$2) {
          final firstEnd = cr.$2;
          final totalSize = cr.$3;
          final finalEnd = chunkReqEnd != null
              ? min(chunkReqEnd, totalSize - 1)
              : totalSize - 1;
          request.response.statusCode = HttpStatus.partialContent;
          for (final key in const [
            'content-type',
            'accept-ranges',
            'etag',
            'last-modified',
          ]) {
            final value = response.headers[key];
            if (value != null) request.response.headers.set(key, value);
          }
          request.response.headers
              .set('content-range', 'bytes $chunkReqStart-$finalEnd/$totalSize');
          request.response.contentLength = finalEnd - chunkReqStart + 1;
          request.response.headers.set('cache-control', 'no-store');
          request.response.bufferOutput = false;
          if (finalEnd <= firstEnd) {
            await _pipeMediaStream(response.stream, request.response);
            return;
          }
          await _pipeMultiWorkerRange(
            target: target,
            firstStream: response.stream,
            nextStart: firstEnd + 1,
            finalEnd: finalEnd,
            totalSize: totalSize,
            sink: request.response,
          );
          return;
        }
      }
      request.response.statusCode = response.statusCode;
      for (final key in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified'
      ]) {
        final value = response.headers[key];
        if (value != null) request.response.headers.set(key, value);
      }
      request.response.headers.set('cache-control', 'no-store');
      if (request.method == 'HEAD') {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      if (mime.toLowerCase().contains('mpegurl') ||
          finalTarget.path.toLowerCase().endsWith('.m3u8')) {
        final body = <int>[];
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 30))) {
          if (_closed ||
              _isCancelled() ||
              body.length + chunk.length > 2 * 1024 * 1024) {
            throw const FormatException('网盘播放列表无效');
          }
          body.addAll(chunk);
        }
        final playlist = _rewritePlaylist(utf8.decode(body), finalTarget);
        final encoded = utf8.encode(playlist);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.removeAll('content-range');
        request.response.headers
            .set('content-type', 'application/vnd.apple.mpegurl');
        request.response.contentLength = encoded.length;
        request.response.add(encoded);
        return;
      }
      request.response.bufferOutput = false;
      await _pipeMediaStream(response.stream, request.response);
    } catch (_) {
      // Do not surface upstream URLs, cookies or socket errors to the player.
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

  Future<void> _pipeMultiWorkerRange({
    required Uri target,
    required Stream<List<int>> firstStream,
    required int nextStart,
    required int finalEnd,
    required int totalSize,
    required HttpResponse sink,
  }) async {
    final windowAbort = Completer<void>();
    _windowAborts.add(windowAbort);
    void abortWindow() {
      if (!windowAbort.isCompleted) windowAbort.complete();
    }

    unawaited(sink.done.then((_) => abortWindow(), onError: (_) => abortWindow()));
    final totalRemaining = finalEnd - nextStart + 1;
    final totalChunks = (totalRemaining + _chunkSize - 1) ~/ _chunkSize;
    final chunks = <int, Future<Uint8List>>{};
    final sizes = <int, int>{};
    final jobs = <Future<void>>[];
    var nextScheduleIndex = 0;
    var writeIndex = 0;
    var scheduling = false;

    void releaseChunk(int index) {
      chunks.remove(index);
      final reserved = sizes.remove(index);
      if (reserved != null) {
        _releaseBytes(reserved);
      }
    }

    Future<Uint8List> fetchChunk(
      int index,
      int start,
      int end,
      int expectedLen,
    ) async {
      StreamSubscription<List<int>>? sub;
      Timer? idleTimer;
      try {
        if (windowAbort.isCompleted || _closed || _isCancelled()) {
          throw const FormatException('chunk cancelled');
        }
        final req = http.AbortableRequest(
          'GET',
          target,
          abortTrigger: windowAbort.future,
        )..followRedirects = false;
        final includeCookie = (_provider != CloudMediaProvider.baidu &&
                _provider != CloudMediaProvider.ali) ||
            (_provider == CloudMediaProvider.baidu &&
                isTrustedBaiduAccountMedia(target));
        _copyHeaders(req.headers, includeCookie: includeCookie);
        req.headers['Accept-Encoding'] = 'identity';
        req.headers['Range'] = 'bytes=$start-$end';
        final (response, _) = await Future.any([
          _send(req),
          windowAbort.future.then<(http.StreamedResponse, Uri)>(
            (_) => throw const FormatException('chunk cancelled'),
          ),
        ]);
        if (windowAbort.isCompleted || _closed || _isCancelled()) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('chunk cancelled');
        }
        final encoding =
            response.headers['content-encoding']?.toLowerCase() ?? '';
        final cr = _parseContentRange(response.headers['content-range']);
        if (response.statusCode != HttpStatus.partialContent ||
            (encoding.isNotEmpty && encoding != 'identity') ||
            cr != (start, end, totalSize)) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('invalid upstream chunk');
        }
        final buffer = Uint8List(expectedLen);
        var offset = 0;
        final done = Completer<Uint8List>();
        void finishChunk([Object? err, StackTrace? st]) {
          idleTimer?.cancel();
          if (!done.isCompleted) {
            if (err != null) {
              done.completeError(err, st);
            } else if (offset != expectedLen) {
              done.completeError(const FormatException('truncated chunk'));
            } else {
              done.complete(buffer);
            }
          }
        }

        void resetIdle() {
          idleTimer?.cancel();
          idleTimer = Timer(const Duration(seconds: 30), () {
            finishChunk(TimeoutException('upstream chunk idle'));
          });
        }

        resetIdle();
        sub = response.stream.listen(
          (part) {
            if (windowAbort.isCompleted || _closed || _isCancelled()) {
              finishChunk(const FormatException('chunk cancelled'));
              return;
            }
            resetIdle();
            if (offset + part.length > expectedLen) {
              finishChunk(const FormatException('oversized chunk'));
              return;
            }
            buffer.setRange(offset, offset + part.length, part);
            offset += part.length;
          },
          onError: finishChunk,
          onDone: finishChunk,
          cancelOnError: true,
        );
        _upstreams.add(sub);
        final abortSub = windowAbort.future.asStream().listen((_) {
          finishChunk(const FormatException('chunk cancelled'));
        });
        try {
          return await done.future;
        } finally {
          await abortSub.cancel();
        }
      } catch (_) {
        releaseChunk(index);
        rethrow;
      } finally {
        idleTimer?.cancel();
        if (sub != null) {
          _upstreams.remove(sub);
          try {
            await sub.cancel();
          } catch (_) {}
        }
      }
    }

    Future<void> pumpSchedule() async {
      if (scheduling) return;
      scheduling = true;
      try {
        while (!windowAbort.isCompleted &&
            !_closed &&
            !_isCancelled() &&
            nextScheduleIndex < totalChunks &&
            nextScheduleIndex < writeIndex + _chunkWorkers) {
          final idx = nextScheduleIndex;
          final cStart = nextStart + idx * _chunkSize;
          final cEnd = min(cStart + _chunkSize - 1, finalEnd);
          final cLen = cEnd - cStart + 1;
          await _waitForBufferSpace(cLen, windowAbort.future);
          if (windowAbort.isCompleted ||
              _closed ||
              _isCancelled() ||
              idx >= writeIndex + _chunkWorkers) {
            break;
          }
          nextScheduleIndex++;
          _reserveBytes(cLen);
          sizes[idx] = cLen;
          final fut = fetchChunk(idx, cStart, cEnd, cLen);
          chunks[idx] = fut;
          final job = fut.then<void>((_) {}, onError: (Object _) {});
          jobs.add(job);
          unawaited(job.whenComplete(() => jobs.remove(job)));
        }
      } catch (_) {
        // Aborted while waiting for buffer space.
      } finally {
        scheduling = false;
      }
    }

    try {
      // Kick off concurrent workers for chunks 1..N while chunk 0 streams.
      unawaited(pumpSchedule());
      await _pipeMediaStream(firstStream, sink);
      var pendingFlushBytes = 0;
      while (writeIndex < totalChunks) {
        if (windowAbort.isCompleted || _closed || _isCancelled()) break;
        await pumpSchedule();
        final future = chunks[writeIndex];
        if (future == null) break;
        final bytes = await Future.any([
          future,
          windowAbort.future.then<Uint8List>(
            (_) => throw const FormatException('chunk cancelled'),
          ),
        ]);
        if (windowAbort.isCompleted || _closed || _isCancelled()) {
          releaseChunk(writeIndex);
          break;
        }
        try {
          sink.add(bytes);
        } catch (_) {
          releaseChunk(writeIndex);
          break;
        }
        pendingFlushBytes += bytes.length;
        releaseChunk(writeIndex);
        writeIndex++;
        unawaited(pumpSchedule());
        if (pendingFlushBytes >= _flushThresholdBytes) {
          pendingFlushBytes = 0;
          try {
            await Future.any([
              sink.flush().timeout(const Duration(seconds: 30)),
              windowAbort.future,
            ]);
          } catch (_) {
            break;
          }
        }
      }
      if (!windowAbort.isCompleted &&
          !_closed &&
          !_isCancelled() &&
          pendingFlushBytes > 0) {
        try {
          await sink.flush().timeout(const Duration(seconds: 30));
        } catch (_) {}
      }
    } finally {
      abortWindow();
      _windowAborts.remove(windowAbort);
      for (final idx in sizes.keys.toList()) {
        releaseChunk(idx);
      }
      if (jobs.isNotEmpty) {
        await Future.wait(jobs.toList());
      }
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

    // Abort the upstream Range download immediately if the player closes its
    // loopback socket (e.g. after probing ftyp/moov or seeking in a 4K MP4).
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
        if (pendingBytes >= _flushThresholdBytes) {
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

  Future<(http.StreamedResponse, Uri)> _send(http.Request initial) async {
    var request = initial;
    for (var redirects = 0;; redirects++) {
      final response =
          await _client.send(request).timeout(const Duration(seconds: 20));
      if (_provider == CloudMediaProvider.quark &&
          !_closed &&
          !_isCancelled() &&
          await _isCurrent()) {
        final cookie = _headers['Cookie'];
        if (cookie != null) {
          try {
            _headers['Cookie'] = QuarkAccountSession.refreshOperationCookie(
                cookie, response.headers['set-cookie'], request.url);
          } catch (_) {
            await response.stream.listen((_) {}).cancel();
            rethrow;
          }
        }
      }
      final allowsRedirect = _provider == CloudMediaProvider.quark ||
          _provider == CloudMediaProvider.baidu ||
          _provider == CloudMediaProvider.ali;
      final maxRedirects = _provider == CloudMediaProvider.baidu ? 5 : 3;
      if (!allowsRedirect ||
          !const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return (response, request.url);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      final next = location == null ? null : request.url.resolve(location);
      final allowedRedirect = next != null &&
          (_provider == CloudMediaProvider.baidu
              ? isSafeBaiduRedirectTarget(next)
              : _trusted(next));
      if (redirects >= maxRedirects ||
          !allowedRedirect ||
          _closed ||
          _isCancelled() ||
          !await _isCurrent()) {
        throw const FormatException('网盘媒体重定向无效');
      }
      final keepCookie = (_provider != CloudMediaProvider.baidu &&
              _provider != CloudMediaProvider.ali) ||
          (_provider == CloudMediaProvider.baidu &&
              isTrustedBaiduAccountMedia(next));
      request = initial is http.AbortableRequest
          ? (http.AbortableRequest(
              initial.method,
              next,
              abortTrigger: initial.abortTrigger,
            )..followRedirects = false)
          : (http.Request(initial.method, next)..followRedirects = false);
      for (final entry in initial.headers.entries) {
        if (!keepCookie && entry.key.toLowerCase() == 'cookie') continue;
        request.headers[entry.key] = entry.value;
      }
      _copyHeaders(request.headers, includeCookie: keepCookie);
    }
  }

  void _copyHeaders(Map<String, String> target, {required bool includeCookie}) {
    for (final entry in _headers.entries) {
      final lower = entry.key.toLowerCase();
      if (!includeCookie && lower == 'cookie') continue;
      if (_provider == CloudMediaProvider.ali &&
          const {'cookie', 'authorization', 'x-share-token'}.contains(lower)) {
        continue;
      }
      target[entry.key] = entry.value;
    }
  }

  String _rewritePlaylist(String text, Uri origin) {
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('网盘未返回有效播放列表');
    }
    String media(String value) {
      final uri = origin.resolve(value);
      if (_trusted(uri)) return urlFor(uri).toString();
      // Signed external CDN resources remain anonymous. Never pass the account
      // headers to the native decoder, including for HLS keys and segments.
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.host.isEmpty ||
          !uri.host.contains('.') ||
          InternetAddress.tryParse(uri.host) != null ||
          uri.host.endsWith('.localhost')) {
        throw const FormatException('网盘播放列表包含无效地址');
      }
      return uri.toString();
    }

    return text.split('\n').map((line) {
      final value = line.trim();
      if (value.isEmpty) return line;
      if (!value.startsWith('#')) return media(value);
      return line.replaceAllMapped(
          RegExp(r'URI="([^"]+)"'), (match) => 'URI="${media(match[1]!)}"');
    }).join('\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _headers.clear();
    _targets.clear();
    _paths.clear();
    for (final abort in _windowAborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _windowAborts.clear();
    final signal = _spaceSignal;
    if (signal != null && !signal.isCompleted) {
      _spaceSignal = null;
      signal.complete();
    }
    final activeUpstreams = _upstreams.toList();
    _upstreams.clear();
    for (final sub in activeUpstreams) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _client.close();
    await _server.close(force: true);
  }
}

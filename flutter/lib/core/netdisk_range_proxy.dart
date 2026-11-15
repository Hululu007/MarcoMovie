import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'doh_resolver.dart';

/// Credentials are selected for EVERY redirect hop, never inherited from the
/// preceding request. Do not put multi-tenant CDN domains (e.g. aliyuncs.com)
/// in [cookieDomains]. A signed CDN URL normally needs no account token.
class NetdiskHeaderPolicy {
  NetdiskHeaderPolicy({
    Map<String, String> headers = const {},
    Set<String> cookieDomains = const {},
    Set<String> credentialOrigins = const {},
  })  : headers = Map.unmodifiable(headers),
        cookieDomains = Set.unmodifiable(cookieDomains),
        credentialOrigins = Set.unmodifiable(credentialOrigins);

  final Map<String, String> headers;
  final Set<String> cookieDomains;
  final Set<String> credentialOrigins;

  Map<String, String> forUri(Uri uri) {
    final exact = credentialOrigins.contains(uri.origin);
    final cookieAllowed = exact ||
        uri.scheme == 'https' &&
            cookieDomains.any((d) => uri.host == d || uri.host.endsWith('.$d'));
    return {
      for (final entry in headers.entries)
        if (switch (entry.key.toLowerCase()) {
          'cookie' => cookieAllowed,
          'authorization' ||
          'x-share-token' ||
          'x-device-id' ||
          'x-signature' =>
            exact,
          'user-agent' || 'referer' || 'accept' || 'accept-language' => true,
          _ => false,
        })
          entry.key: entry.value,
      'Accept-Encoding': 'identity',
    };
  }
}

class NetdiskProxyException implements Exception {
  const NetdiskProxyException(this.code);
  final String code;
  @override
  String toString() => 'Netdisk proxy: $code';
}

/// One playback session, one loopback server and one revocable random token.
/// Six asynchronous socket workers (no CPU-bound isolate copies) fetch fixed
/// chunks. At most (workers + 1) chunks are retained, INCLUDING in-flight
/// reservations and the chunk being written to a slow player. No file cache
/// grows with file size. A new GET preempts the old window, including a pending
/// connect/read, so an MKV Cues seek never waits for sequential downloading.
class NetdiskRangeProxy {
  NetdiskRangeProxy({
    this.workers = 6,
    this.chunkSize = 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  }) {
    if (workers < 4 ||
        workers > 6 ||
        chunkSize < 64 * 1024 ||
        chunkSize > 2 * 1024 * 1024) {
      throw ArgumentError('Use 4..6 workers and 64 KiB..2 MiB chunks');
    }
  }

  final int workers;
  final int chunkSize;
  final Duration timeout;
  static const memoryLimit = 24 * 1024 * 1024;
  final _token = _randomToken();
  final _resources = <String, _Resource>{};
  final _controlClients = <HttpClient>{};
  final _responseUris = Expando<Uri>();
  HttpServer? _server;
  Future<HttpServer>? _starting;
  _RangeWindow? _window;
  Future<void> _retired = Future<void>.value();
  Future<void>? _closing;
  bool _closed = false;
  int _sequence = 0;
  int _requestGeneration = 0;
  int _reserved = 0;
  int _peakReserved = 0;
  int _cancelledWindows = 0;

  int get bufferedBytes => _reserved;
  int get peakBufferedBytes => _peakReserved;
  int get cancelledWindows => _cancelledWindows;

  /// [length] may come from the drive listing (64-bit byte count). Every CDN
  /// fragment still has its Content-Range checked against that length.
  Future<Uri> register({
    required Uri upstream,
    required NetdiskHeaderPolicy policy,
    int? length,
    String contentType = 'application/octet-stream',
    Future<void> Function()? validateSession,
    bool playlist = false,
    bool auxiliary = false,
  }) async {
    _validateUrl(upstream);
    if (_closed) throw const NetdiskProxyException('closed');
    if (length != null && length < 0) throw ArgumentError.value(length);
    final server = await (_starting ??= _start());
    if (_closed) throw const NetdiskProxyException('closed');
    final id = '${++_sequence}';
    _resources[id] = _Resource(
        upstream, policy, length, contentType, validateSession, playlist)
      ..hlsChild = auxiliary;
    return Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/$_token/$id/${playlist ? 'index.m3u8' : 'media'}');
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) {
      unawaited(_handle(request));
    });
    return server;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _requestGeneration++;
    final window = _window;
    _window = null;
    window?.cancel();
    for (final client in _controlClients.toList()) {
      client.close(force: true);
    }
    _resources.clear();
    if (_starting != null) {
      try {
        await (await _starting!).close(force: true);
      } catch (_) {}
    }
    await window?.drained;
    await _retired;
  }

  void _reserve(int bytes) {
    if (_reserved + bytes > memoryLimit) {
      throw const NetdiskProxyException('memory_limit');
    }
    _reserved += bytes;
    _peakReserved = max(_peakReserved, _reserved);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _RangeWindow? window;
    try {
      final parts = request.uri.pathSegments;
      if (_closed ||
          request.headers.value('host') != '127.0.0.1:${_server?.port}' ||
          parts.length != 3 ||
          !_equalToken(parts[0], _token) ||
          !_resources.containsKey(parts[1])) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'HEAD' && request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set('Allow', 'HEAD, GET');
        return;
      }
      final resource = _resources[parts[1]]!;
      await resource.validate?.call();
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      if (resource.playlist) {
        await _playlist(request, resource);
        return;
      }
      if (resource.hlsChild) {
        await _streamChild(request, resource);
        return;
      }
      final generation = request.method == 'GET' ? ++_requestGeneration : null;
      if (generation != null) {
        final previous = _window;
        _window = null;
        if (previous != null) {
          _cancelledWindows++;
          previous.cancel();
          _retired = Future.wait([_retired, previous.drained]);
        }
        await _retired;
      }
      final size = resource.length ??= await _probe(resource);
      if (_closed || generation != null && generation != _requestGeneration) {
        return;
      }
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.set('Content-Type', resource.contentType);
      final rawRange =
          request.method == 'GET' ? request.headers.value('range') : null;
      final range = _parseRange(rawRange, size);
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('Content-Range', 'bytes */$size');
        response.contentLength = 0;
        return;
      }
      response.statusCode =
          rawRange == null ? HttpStatus.ok : HttpStatus.partialContent;
      if (rawRange != null) {
        response.headers
            .set('Content-Range', 'bytes ${range.$1}-${range.$2}/$size');
      }
      response.contentLength = size == 0 ? 0 : range.$2 - range.$1 + 1;
      if (request.method == 'HEAD' || size == 0) return;
      window = _RangeWindow(this, resource, size);
      _window = window;
      final ownedWindow = window;
      unawaited(response.done.then((_) => ownedWindow.cancel(),
          onError: (Object _) => ownedWindow.cancel()));
      var cursor = range.$1;
      while (cursor <= range.$2) {
        final index = cursor ~/ chunkSize;
        window.fill(index);
        final chunk = await window.get(index);
        final from = cursor - index * chunkSize;
        final count = min(chunk.length - from, range.$2 - cursor + 1);
        response.add(Uint8List.sublistView(chunk, from, from + count));
        await window.race(response.flush().timeout(timeout));
        window.release(index);
        cursor += count;
      }
    } catch (error) {
      try {
        response.statusCode =
            error is NetdiskProxyException && error.code == 'cancelled'
                ? HttpStatus.serviceUnavailable
                : HttpStatus.badGateway;
        response.contentLength = 0;
      } catch (_) {
        try {
          (await response.detachSocket(writeHeaders: false)).destroy();
        } catch (_) {}
      }
    } finally {
      if (window != null) {
        window.cancel();
        if (identical(_window, window)) _window = null;
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<int> _probe(_Resource resource) async {
    final client = _client();
    _controlClients.add(client);
    try {
      final response = await _open(client, resource, 'GET', range: 'bytes=0-0');
      final parsed = _contentRange(response.headers.value('content-range'));
      await response.listen((_) {}).cancel();
      if (response.statusCode != 206 ||
          parsed == null ||
          parsed.$1 != 0 ||
          parsed.$2 != 0) {
        throw const NetdiskProxyException('range_not_supported');
      }
      return parsed.$3;
    } finally {
      client.close(force: true);
      _controlClients.remove(client);
    }
  }

  HttpClient _client() {
    final io = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout
      ..maxConnectionsPerHost = workers
      ..findProxy = (_) => 'DIRECT';
    if (HttpOverrides.current == null) {
      io.connectionFactory = CmsDohResolver.shared.connect;
    }
    return io;
  }

  Future<HttpClientResponse> _open(
      HttpClient client, _Resource resource, String method,
      {String? range}) async {
    var uri = resource.upstream;
    for (var hop = 0; hop <= 5; hop++) {
      _validateUrl(uri);
      await resource.validate?.call();
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      resource.policy.forUri(uri).forEach(request.headers.set);
      if (range != null) request.headers.set('Range', range);
      final response = await request.close().timeout(timeout);
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.listen((_) {}).cancel();
        if (location == null) {
          throw const NetdiskProxyException('invalid_redirect');
        }
        final next = uri.resolve(location);
        if (uri.scheme == 'https' && next.scheme != 'https') {
          throw const NetdiskProxyException('insecure_redirect');
        }
        uri = next;
      } else {
        _responseUris[response] = uri;
        return response;
      }
    }
    throw const NetdiskProxyException('too_many_redirects');
  }

  Future<void> _playlist(HttpRequest request, _Resource resource) async {
    if (_controlClients.length >= 2) throw const NetdiskProxyException('busy');
    final client = _client();
    _controlClients.add(client);
    const limit = 2 * 1024 * 1024;
    _reserve(limit * 2);
    try {
      final upstream = await _open(client, resource, 'GET');
      if (upstream.statusCode != 200) {
        throw const NetdiskProxyException('playlist_unavailable');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in upstream.timeout(timeout)) {
        if (bytes.length + part.length > limit) {
          throw const NetdiskProxyException('playlist_too_large');
        }
        bytes.add(part);
      }
      final body = utf8.decode(bytes.takeBytes());
      if (!body.trimLeft().startsWith('#EXTM3U')) {
        throw const NetdiskProxyException('invalid_playlist');
      }
      String local(String raw) {
        final target =
            (_responseUris[upstream] ?? resource.upstream).resolve(raw);
        _validateUrl(target);
        final key = '${resource.policy.hashCode}|$target';
        var id = _resources.entries
            .where((e) => e.value.childKey == key)
            .firstOrNull
            ?.key;
        if (id == null) {
          if (_resources.length >= 12000) {
            throw const NetdiskProxyException('playlist_too_large');
          }
          id = '${++_sequence}';
          _resources[id] = _Resource(
              target,
              resource.policy,
              null,
              'application/octet-stream',
              resource.validate,
              target.path.toLowerCase().endsWith('.m3u8'))
            ..hlsChild = true
            ..childKey = key;
        }
        return 'http://127.0.0.1:${_server!.port}/$_token/$id/media';
      }

      final rewritten = body.split('\n').map((line) {
        final value = line.trim();
        if (value.isEmpty) return line;
        if (!value.startsWith('#')) return local(value);
        return line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'), (m) => 'URI="${local(m[1]!)}"');
      }).join('\n');
      final output = utf8.encode(rewritten);
      if (output.length > limit * 2) {
        throw const NetdiskProxyException('playlist_too_large');
      }
      request.response.headers
          .set('Content-Type', 'application/vnd.apple.mpegurl');
      request.response.contentLength = output.length;
      if (request.method == 'GET') request.response.add(output);
    } finally {
      _reserved -= limit * 2;
      client.close(force: true);
      _controlClients.remove(client);
    }
  }

  Future<void> _streamChild(HttpRequest request, _Resource resource) async {
    if (_controlClients.length >= 2) throw const NetdiskProxyException('busy');
    final client = _client();
    _controlClients.add(client);
    try {
      final upstream = await _open(client, resource, request.method,
          range: request.headers.value('range'));
      if (upstream.statusCode != 200 && upstream.statusCode != 206) {
        throw const NetdiskProxyException('segment_unavailable');
      }
      final response = request.response;
      response.statusCode = upstream.statusCode;
      for (final name in ['content-type', 'content-range', 'accept-ranges']) {
        final value = upstream.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      response.contentLength = upstream.contentLength;
      if (request.method == 'GET') {
        await for (final chunk in upstream.timeout(timeout)) {
          response.add(chunk);
          await response.flush().timeout(timeout);
        }
      }
    } finally {
      client.close(force: true);
      _controlClients.remove(client);
    }
  }

  static (int, int)? _parseRange(String? raw, int size) {
    if (raw == null) return (0, size - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(raw.trim());
    if (match == null || size == 0) return null;
    final a = match[1]!, b = match[2]!;
    if (a.isEmpty) {
      final suffix = int.tryParse(b);
      return suffix == null || suffix <= 0
          ? null
          : (max(0, size - suffix), size - 1);
    }
    final start = int.tryParse(a), end = b.isEmpty ? size - 1 : int.tryParse(b);
    if (start == null || end == null || start >= size || start > end) {
      return null;
    }
    return (start, min(end, size - 1));
  }

  static (int, int, int)? _contentRange(String? raw) {
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(raw ?? '');
    if (m == null) return null;
    final start = int.tryParse(m[1]!),
        end = int.tryParse(m[2]!),
        size = int.tryParse(m[3]!);
    if (start == null ||
        end == null ||
        size == null ||
        start > end ||
        end >= size) {
      return null;
    }
    return (start, end, size);
  }

  static void _validateUrl(Uri uri) {
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const NetdiskProxyException('invalid_upstream');
    }
  }

  static String _randomToken() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static bool _equalToken(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

class _Resource {
  _Resource(this.upstream, this.policy, this.length, this.contentType,
      this.validate, this.playlist);
  final Uri upstream;
  final NetdiskHeaderPolicy policy;
  int? length;
  final String contentType;
  final Future<void> Function()? validate;
  final bool playlist;
  bool hlsChild = false;
  String? childKey;
}

class _RangeWindow {
  _RangeWindow(this.owner, this.resource, this.size) : client = owner._client();
  final NetdiskRangeProxy owner;
  final _Resource resource;
  final int size;
  final HttpClient client;
  final _cancelled = Completer<void>();
  final _chunks = <int, Future<Uint8List>>{};
  final _sizes = <int, int>{};
  final _jobs = <Future<void>>[];
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get drained => Future.wait(_jobs);

  Future<T> race<T>(Future<T> future) => Future.any([
        future,
        _cancelled.future
            .then<T>((_) => throw const NetdiskProxyException('cancelled')),
      ]);

  void fill(int index) {
    if (cancelled) throw const NetdiskProxyException('cancelled');
    for (var i = index;
        i < index + owner.workers && i * owner.chunkSize < size;
        i++) {
      if (_chunks.containsKey(i)) continue;
      final length = min(owner.chunkSize, size - i * owner.chunkSize);
      owner._reserve(length);
      _sizes[i] = length;
      final future = _fetch(i, length);
      _chunks[i] = future;
      final job = future.then<void>((_) {}, onError: (Object _) {});
      _jobs.add(job);
      unawaited(job.whenComplete(() => _jobs.remove(job)));
    }
  }

  Future<Uint8List> get(int index) => race(_chunks[index]!);

  Future<Uint8List> _fetch(int index, int length) async {
    final start = index * owner.chunkSize;
    final end = start + length - 1;
    try {
      final response = await race(
          owner._open(client, resource, 'GET', range: 'bytes=$start-$end'));
      final range = NetdiskRangeProxy._contentRange(
          response.headers.value('content-range'));
      if (response.statusCode != 206 ||
          range != (start, end, size) ||
          response.headers.value('content-encoding') != null &&
              response.headers.value('content-encoding') != 'identity' ||
          response.contentLength >= 0 && response.contentLength != length) {
        await response.listen((_) {}).cancel();
        throw const NetdiskProxyException('invalid_content_range');
      }
      final bytes = Uint8List(length);
      var offset = 0;
      final iterator = StreamIterator(response.timeout(owner.timeout));
      try {
        while (await race(iterator.moveNext())) {
          final part = iterator.current;
          if (offset + part.length > length) {
            throw const NetdiskProxyException('oversized_fragment');
          }
          bytes.setRange(offset, offset + part.length, part);
          offset += part.length;
        }
      } finally {
        await iterator.cancel();
      }
      if (offset != length || cancelled) {
        throw const NetdiskProxyException('truncated_fragment');
      }
      return bytes;
    } catch (_) {
      release(index);
      rethrow;
    }
  }

  void release(int index) {
    _chunks.remove(index);
    owner._reserved -= _sizes.remove(index) ?? 0;
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
    client.close(force: true);
    for (final index in _sizes.keys.toList()) {
      release(index);
    }
  }
}

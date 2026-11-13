import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'quark_account.dart';
import 'resilient_http_client.dart';

enum CloudMediaProvider { uc, quark, baidu }

/// A player-owned capability for one cloud file and its quality variants.
/// Account headers stay here, scoped to the selected provider's HTTPS hosts.
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
      DateTime Function() clock)
      : _clock = clock,
        _created = clock() {
    urlFor(target);
    _server.listen(_serve);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sweep());
  }

  static const int _maxConcurrentRequests = 24;
  static const int _flushThresholdBytes = 4 * 1024 * 1024;

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
  final _requests = <HttpRequest>{};
  final _upstreams = <StreamSubscription<List<int>>>{};
  final DateTime Function() _clock;
  final DateTime _created;
  Timer? _timer;
  bool _closed = false;
  bool _checking = false;

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

  bool _trusted(Uri uri) => switch (_provider) {
        CloudMediaProvider.quark => isTrustedQuarkMedia(uri),
        CloudMediaProvider.baidu => isTrustedBaiduMedia(uri),
        CloudMediaProvider.uc => isTrustedUcMedia(uri),
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

  static Future<CloudMediaLease> open(
      {required Uri target,
      required Map<String, String> headers,
      required bool Function() isCancelled,
      required Future<bool> Function() isCurrent,
      CloudMediaProvider provider = CloudMediaProvider.uc,
      DateTime Function()? clock,
      http.Client? client}) async {
    final validTarget = switch (provider) {
      CloudMediaProvider.quark => isTrustedQuarkMedia(target),
      CloudMediaProvider.baidu => isTrustedBaiduMedia(target),
      CloudMediaProvider.uc => isTrustedUcMedia(target),
    };
    if (!validTarget) {
      client?.close();
      throw const FormatException('网盘返回的媒体域名无法安全携带账号会话');
    }
    if (isCancelled() || !await isCurrent()) {
      client?.close();
      throw const FormatException('播放已取消或网盘账号已切换');
    }
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
        clock ?? DateTime.now);
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
      final includeCookie = _provider != CloudMediaProvider.baidu ||
          isTrustedBaiduAccountMedia(target);
      _copyHeaders(upstream.headers, includeCookie: includeCookie);
      upstream.headers['Accept-Encoding'] = 'identity';
      final range = request.headers.value('range');
      if (range != null) {
        if (!RegExp(r'^bytes=\d*-\d*$').hasMatch(range) || range == 'bytes=-') {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        final isPlaylistTarget = target.path.toLowerCase().endsWith('.m3u8') ||
            (!target.path.toLowerCase().endsWith('.ts') &&
                target.query.toLowerCase().contains('m3u8'));
        if (!isPlaylistTarget) {
          upstream.headers['Range'] = range;
        }
      }
      final (response, finalTarget) = await _send(upstream);
      if (_closed || _isCancelled() || !await _isCurrent()) {
        await response.stream.listen((_) {}).cancel();
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      // UC keeps its existing no-redirect policy. Quark redirects are followed
      // only after checking every destination against the same provider scope.
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
          _provider == CloudMediaProvider.baidu;
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
      final keepCookie = _provider != CloudMediaProvider.baidu ||
          isTrustedBaiduAccountMedia(next);
      request = http.Request(initial.method, next)..followRedirects = false;
      for (final entry in initial.headers.entries) {
        if (!keepCookie && entry.key.toLowerCase() == 'cookie') continue;
        request.headers[entry.key] = entry.value;
      }
      _copyHeaders(request.headers, includeCookie: keepCookie);
    }
  }

  void _copyHeaders(Map<String, String> target, {required bool includeCookie}) {
    for (final entry in _headers.entries) {
      if (!includeCookie && entry.key.toLowerCase() == 'cookie') continue;
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

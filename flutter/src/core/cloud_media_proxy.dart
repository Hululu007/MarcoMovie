import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'quark_account.dart';

enum CloudMediaProvider { uc, quark }

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

  bool _trusted(Uri uri) => _provider == CloudMediaProvider.quark
      ? isTrustedQuarkMedia(uri)
      : isTrustedUcMedia(uri);

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
    if (!(provider == CloudMediaProvider.quark
        ? isTrustedQuarkMedia(target)
        : isTrustedUcMedia(target))) {
      client?.close();
      throw const FormatException('网盘返回的媒体域名无法安全携带账号会话');
    }
    if (isCancelled() || !await isCurrent()) {
      client?.close();
      throw const FormatException('播放已取消或网盘账号已切换');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64Url
        .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    return CloudMediaLease._(server, client ?? http.Client(), target, provider,
        Map.of(headers), isCancelled, isCurrent, token, clock ?? DateTime.now);
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
    if (_requests.length >= 4) {
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
      upstream.headers.addAll(_headers);
      upstream.headers['Accept-Encoding'] = 'identity';
      final range = request.headers.value('range');
      if (range != null) {
        if (!RegExp(r'^bytes=\d*-\d*$').hasMatch(range) || range == 'bytes=-') {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        if (!target.path.toLowerCase().endsWith('.m3u8')) {
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
      if (_provider == CloudMediaProvider.quark &&
          (mime.toLowerCase().contains('mpegurl') ||
              finalTarget.path.toLowerCase().endsWith('.m3u8'))) {
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
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (_closed || _isCancelled()) break;
        request.response.add(chunk);
        await request.response.flush().timeout(const Duration(seconds: 30));
      }
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
      if (_provider != CloudMediaProvider.quark ||
          !const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return (response, request.url);
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      final next = location == null ? null : request.url.resolve(location);
      if (redirects >= 3 ||
          next == null ||
          !_trusted(next) ||
          _closed ||
          _isCancelled() ||
          !await _isCurrent()) {
        throw const FormatException('网盘媒体重定向无效');
      }
      request = http.Request(initial.method, next)
        ..followRedirects = false
        ..headers.addAll(initial.headers)
        ..headers.addAll(_headers);
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
    _client.close();
    await _server.close(force: true);
  }
}

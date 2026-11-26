// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import 'catpaw_crypto.dart';

/// In-process Dart + QuickJS-NG implementation of the CatPaw/DRPY/Guard
/// loopback host protocol (`shared/catpaw/host.cjs`).
///
/// Used on HarmonyOS NEXT (`ohos`), where QuickJS-NG (`libquickjs_c_bridge_plugin.so`)
/// and verified `assets/catpaw/` files are bundled inside the HAP while no
/// standalone Node.js binary exists.
class EmbeddedCatPawEngine {
  static const int _maxRuntimes = 6;
  static const int _maxBundleBytes = 16 * 1024 * 1024;
  static const int _maxResultBytes = 6 * 1024 * 1024;
  static const String drpyRuntime = 'drpy2-ca23ffdb-1';
  static final RegExp _hashPattern = RegExp(r'^[a-f0-9]{64}$');

  static const Set<String> _baseAdapters = {
    'dm84-v1',
    'auete-v1',
    'bttwoo-v1',
    'appgz-v1',
    't4-v1',
    'apptt-v1',
    'fy-v1',
  };

  static const Set<String> _ftyAdapters = {
    'jpys-v1',
    'jpj-v1',
    'nmyswv-v1',
    'hmys-v1',
    'app99-v1',
    'appsx-v1',
    'newcz-v1',
    'libvio-v1',
    'ygp-v1',
    'kanqiu-v1',
    'doubao-v1',
    'livegz-v1',
    'alllive-v1',
    'tingshu275-v1',
    'yueting-v1',
    'seedhub-v1',
    'szps-v1',
    'ypanso-v1',
    'bpanso-v1',
    'kkss-v1',
    'uuss-v1',
    'jumitv-v1',
  };

  static const Set<String> _wexAdapters = {
    'wexappv7-v1',
    'wexguazi-v1',
    'wexduboku-v1',
    'wexwencai-v1',
    'wexfengye-v1',
    'wexjianpian-v1',
    'wexjuxiafan-v1',
    'wexrebo-v1',
    'wexbobo-v1',
    'wexikanbot-v1',
    'wexyiys-v1',
    'wexhanxiaoquan-v1',
    'wexduoduo-v1',
    'wexhuban-v1',
    'wexkuaiying-v1',
    'wexlabi-v1',
    'wexmuou-v1',
    'wexshandian-v1',
    'wexxiaopan-v1',
    'wexzhizhen-v1',
    'wexwogg-v1',
    'wexhuajuan-v1',
    'wexjutou-v1',
    'wexzhinan-v1',
    'wexwoniu-v1',
    'wexpianku-v1',
    'wexqiwei-v1',
    'wexyidong-v1',
    'wexaipanso-v1',
    'wexhaiyin-v1',
    'wexquanpan-v1',
    'wexkaka-v1',
    'wexmodu-v1',
    'wexhaokan-v1',
    'wexqimiao-v1',
    'wexkuwoa-v1',
    'wexqingting-v1',
    'wexsportguazi-v1',
    'wexkafei-v1',
    'wexkanqiutong-v1',
    'wexkanqiu-v1',
    'wexwwe-v1',
  };

  static const Set<String> _needsExtensionAdapters = {'t4-v1', 'apptt-v1'};

  final Directory root;
  final String secret;
  final HttpServer _server;
  final _SyncHttpBridge _syncHttp;

  final Map<String, _DrpyWorkerHandle> _workers = {};
  final Map<String, Future<_DrpyWorkerHandle>> _loading = {};
  final Map<String, int> _releases = {};
  Future<void> _loadQueue = Future<void>.value();
  _BootstrapTask? _bootstrap;
  bool _closing = false;
  bool _resetting = false;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/$secret');
  bool get isClosed => _closing;

  EmbeddedCatPawEngine._({
    required this.root,
    required this.secret,
    required HttpServer server,
    required _SyncHttpBridge syncHttp,
  }) : _server = server,
       _syncHttp = syncHttp {
    _server.listen(_handleRequest, onError: (_) {});
  }

  static Future<EmbeddedCatPawEngine> start({required Directory root}) async {
    await root.create(recursive: true);
    final secretBytes = CatPawCrypto.randomBytes(32);
    final secret = secretBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final syncHttp = await _SyncHttpBridge.start();
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return EmbeddedCatPawEngine._(
        root: root,
        secret: secret,
        server: server,
        syncHttp: syncHttp,
      );
    } catch (_) {
      await syncHttp.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _bootstrap?.cancel();
    final handles = _workers.values.toList();
    _workers.clear();
    await Future.wait(handles.map(_stopWorker));
    try {
      await _server.close(force: true);
    } catch (_) {}
    await _syncHttp.close();
  }

  Future<void> _stopWorker(_DrpyWorkerHandle handle) async {
    _syncHttp.cancelWorker(handle.workerId);
    _syncHttp.unregisterManifest(handle.workerId);
    await handle.dispose();
  }

  void _respondJson(HttpResponse res, int status, Object body) {
    try {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.headers.set('Cache-Control', 'no-store');
      res.write(jsonEncode(body));
      unawaited(res.close().catchError((_) {}));
    } catch (_) {}
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final res = req.response;
    try {
      if (_closing || req.headers.value('origin') != null) {
        _respondJson(res, 403, {'error': 'forbidden'});
        return;
      }
      final prefix = '/$secret/';
      final rawUrl = req.uri.toString();
      if (!rawUrl.startsWith(prefix)) {
        _respondJson(res, 403, {'error': 'forbidden'});
        return;
      }
      final route = rawUrl.substring(prefix.length);
      if (route == 'health' && req.method == 'GET') {
        _respondJson(res, 200, {
          'version': 1,
          'runtime': 'quickjs-ng-embedded',
        });
        return;
      }
      if (route == '_reset' && req.method == 'POST') {
        await _handleReset(res);
        return;
      }
      if (route == '_port-bootstrap' && req.method == 'POST') {
        await _handlePortBootstrap(req, res);
        return;
      }
      final match = RegExp(r'^([a-f0-9]{64})(\/.*)$').firstMatch(route);
      if (match == null) {
        _respondJson(res, 404, {'error': 'route'});
        return;
      }
      final hash = match.group(1)!;
      final resource = match.group(2)!;

      if (resource == '/_release' && req.method == 'POST') {
        _releases[hash] = (_releases[hash] ?? 0) + 1;
        final existing = _workers.remove(hash);
        if (existing != null) {
          await _stopWorker(existing);
        }
        _respondJson(res, 200, {'released': true});
        return;
      }
      if (resource == '/_manage' && req.method == 'POST') {
        _respondJson(res, 503, {'error': 'settings_unavailable'});
        return;
      }

      // Check whether this hash belongs to a Node.js CatPaw service bundle.
      final folder = Directory('${root.path}/$hash');
      final indexFile = File('${folder.path}/index.cjs');
      final manifestFile = File('${folder.path}/drpy.json');
      if (await indexFile.exists() && !await manifestFile.exists()) {
        _respondJson(res, 501, {'error': 'catpaw_node_unsupported'});
        return;
      }

      if (resource == '/api/drpy' && req.method == 'POST') {
        await _handleDrpyCall(req, res, hash);
        return;
      }
      if ((req.method == 'GET' || req.method == 'HEAD') &&
          (resource == '/proxy' || resource.startsWith('/proxy?'))) {
        await _handleDrpyProxy(req, res, hash);
        return;
      }
      _respondJson(res, 403, {'error': 'route_not_exposed'});
    } catch (_) {
      _respondJson(res, 500, {'error': 'internal_error'});
    }
  }

  Future<void> _handleReset(HttpResponse res) async {
    if (_resetting) {
      _respondJson(res, 409, {'error': 'runtime_reset'});
      return;
    }
    _resetting = true;
    try {
      final pending = _bootstrap;
      pending?.cancel();
      for (final hash in {..._workers.keys, ..._loading.keys}) {
        _releases[hash] = (_releases[hash] ?? 0) + 1;
      }
      final handles = _workers.values.toList();
      _workers.clear();
      await Future.wait(handles.map(_stopWorker));
      await _loadQueue;
      await Future.wait(
        _loading.values.map((f) => f.then<void>((_) {}, onError: (_) {})),
      );
      if (pending != null) await pending.done;
      _respondJson(res, 200, {'reset': true});
    } finally {
      _resetting = false;
    }
  }

  Future<Uint8List> _readRequestBytes(HttpRequest req, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (builder.length + chunk.length > maxBytes) {
        throw const FormatException('payload_too_large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _handlePortBootstrap(HttpRequest req, HttpResponse res) async {
    if (_resetting || _closing) {
      await req.drain<void>().catchError((_) {});
      _respondJson(res, 409, {'error': 'runtime_reset'});
      return;
    }
    if (_bootstrap != null) {
      await req.drain<void>().catchError((_) {});
      _respondJson(res, 429, {'error': 'bootstrap_busy'});
      return;
    }
    final task = _BootstrapTask();
    _bootstrap = task;
    var status = 200;
    Map<String, Object?> payload = const {'error': 'guard_artifact_invalid'};
    try {
      final rawBytes = await _readRequestBytes(
        req,
        17 * 1024,
      ).timeout(const Duration(seconds: 2));
      final body = jsonDecode(utf8.decode(rawBytes));
      if (body is! Map) throw const FormatException('bootstrap_request');
      final adapter = body['adapter'];
      final artifactHash = body['artifactHash'];
      final version = body['version'];
      final hasExt = body.containsKey('extension');
      final extension = body['extension'];

      final isOptionalExt =
          _ftyAdapters.contains(adapter) || _wexAdapters.contains(adapter);
      final needsExt = _needsExtensionAdapters.contains(adapter);
      final allowedKeys = <String>{
        'adapter',
        'artifactHash',
        'version',
        if (needsExt || (isOptionalExt && hasExt)) 'extension',
      };
      final bodyKeys = body.keys.map((k) => k.toString()).toSet();
      if (bodyKeys.length != allowedKeys.length ||
          !bodyKeys.containsAll(allowedKeys) ||
          version != 1 ||
          adapter is! String ||
          (!isOptionalExt && !_baseAdapters.contains(adapter)) ||
          artifactHash is! String ||
          !_hashPattern.hasMatch(artifactHash)) {
        throw const FormatException('bootstrap_request');
      }
      if (needsExt &&
          (extension is! String ||
              extension.trim().isEmpty ||
              utf8.encode(extension).length > 16 * 1024)) {
        throw const FormatException('bootstrap_request');
      }
      if (isOptionalExt &&
          hasExt &&
          (extension is! String || utf8.encode(extension).length > 16 * 1024)) {
        throw const FormatException('bootstrap_request');
      }

      final importsDir = Directory('${root.path}/imports');
      if (await FileSystemEntity.isLink(importsDir.path) ||
          !await importsDir.exists()) {
        throw const FormatException('guard_artifact_invalid');
      }
      final artifactFile = File('${importsDir.path}/$artifactHash.jar');
      if (await FileSystemEntity.isLink(artifactFile.path) ||
          !await artifactFile.exists()) {
        throw const FormatException('guard_artifact_invalid');
      }
      final stat = await artifactFile.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size <= 0 ||
          stat.size > _maxBundleBytes) {
        throw const FormatException('guard_artifact_invalid');
      }
      final artifactBytes = await artifactFile.readAsBytes();
      if (artifactBytes.length != stat.size ||
          sha256.convert(artifactBytes).toString() != artifactHash) {
        throw const FormatException('guard_artifact_integrity');
      }

      if (task.cancelled || _closing || _resetting) {
        throw const FormatException('bootstrap_cancelled');
      }

      final result = await _runGuardBootstrapInIsolate(
        task: task,
        rootPath: root.path,
        artifactBytes: artifactBytes,
        adapter: adapter,
        extension: extension is String ? extension : null,
      );
      final err = result['error'];
      if (err is String && err.isNotEmpty) {
        throw FormatException(err);
      }
      payload = result;
    } on TimeoutException {
      status = 504;
      payload = const {'error': 'bootstrap_timeout'};
    } on FormatException catch (e) {
      final code = const {
        'guard_artifact_unsupported',
        'guard_artifact_integrity',
        'guard_artifact_invalid',
        'bootstrap_timeout',
        'bootstrap_request',
      }.contains(e.message)
          ? e.message
          : 'guard_artifact_invalid';
      status = code == 'bootstrap_request'
          ? 400
          : code == 'bootstrap_timeout'
          ? 504
          : 422;
      payload = {'error': code};
    } catch (_) {
      status = 422;
      payload = const {'error': 'guard_artifact_invalid'};
    } finally {
      task.complete();
      if (identical(_bootstrap, task)) _bootstrap = null;
    }
    if (!_closing) {
      _respondJson(res, status, payload);
    }
  }

  Future<Map<String, Object?>> _runGuardBootstrapInIsolate({
    required _BootstrapTask task,
    required String rootPath,
    required Uint8List artifactBytes,
    required String adapter,
    required String? extension,
  }) async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    Isolate? isolate;
    final completer = Completer<Map<String, Object?>>();

    void finish(Map<String, Object?> value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    receivePort.listen((dynamic message) {
      if (message is Map) {
        finish(
          message.map((key, value) => MapEntry(key.toString(), value as Object?)),
        );
      } else {
        finish(const {'error': 'guard_artifact_invalid'});
      }
    });
    exitPort.listen((_) {
      finish(const {'error': 'guard_artifact_invalid'});
    });

    final timer = Timer(const Duration(milliseconds: 3800), () {
      isolate?.kill(priority: Isolate.immediate);
      finish(const {'error': 'bootstrap_timeout'});
    });
    task.onCancel = () {
      isolate?.kill(priority: Isolate.immediate);
      finish(const {'error': 'bootstrap_cancelled'});
    };

    try {
      isolate = await Isolate.spawn(
        _guardBootstrapIsolateEntry,
        [
          receivePort.sendPort,
          rootPath,
          TransferableTypedData.fromList([artifactBytes]),
          adapter,
          extension,
        ],
        onExit: exitPort.sendPort,
      );
      if (task.cancelled) {
        isolate.kill(priority: Isolate.immediate);
        return const {'error': 'bootstrap_cancelled'};
      }
      return await completer.future;
    } finally {
      timer.cancel();
      task.onCancel = null;
      receivePort.close();
      exitPort.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<_DrpyWorkerHandle> _loadDrpyWorker(String hash) {
    if (_resetting || _closing) {
      return Future.error(StateError('runtime_reset'));
    }
    final existing = _workers[hash];
    if (existing != null && !existing.disposed) {
      return Future.value(existing);
    }
    final pending = _loading[hash];
    if (pending != null) return pending;

    final epoch = _releases[hash] ?? 0;
    final queuedUntil = DateTime.now().add(const Duration(seconds: 20));
    final created = _loadQueue.then(
      (_) => _createDrpyWorker(hash, epoch, queuedUntil),
    );
    _loadQueue = created.then<void>((_) {}, onError: (_) {});
    final ready = created.whenComplete(() {
      if (identical(_loading[hash], created)) _loading.remove(hash);
    });
    _loading[hash] = ready;
    return ready;
  }

  Future<_DrpyWorkerHandle> _createDrpyWorker(
    String hash,
    int epoch,
    DateTime queuedUntil,
  ) async {
    if (!_hashPattern.hasMatch(hash)) throw StateError('bundle_id');
    if ((_releases[hash] ?? 0) != epoch || _closing || _resetting) {
      throw StateError('bundle_released');
    }
    final existing = _workers[hash];
    if (existing != null && !existing.disposed) return existing;

    while (_workers.length >= _maxRuntimes) {
      final now = DateTime.now();
      final playedEntries = _workers.entries
          .where(
            (e) =>
                e.value.playedAt != null &&
                now.difference(e.value.playedAt!).inMinutes <= 15,
          )
          .toList()
        ..sort((a, b) => b.value.playedAt!.compareTo(a.value.playedAt!));
      final protectedPlayed = playedEntries.take(2).map((e) => e.key).toSet();

      final candidates = _workers.entries
          .where(
            (e) => e.value.activeCalls == 0 && !protectedPlayed.contains(e.key),
          )
          .toList()
        ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));

      if (candidates.isEmpty) {
        if (_closing ||
            _resetting ||
            DateTime.now().isAfter(queuedUntil) ||
            (_releases[hash] ?? 0) != epoch) {
          throw StateError('runtime_limit');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      final victim = candidates.first;
      _workers.remove(victim.key);
      await _stopWorker(victim.value);
    }

    if (DateTime.now().isAfter(queuedUntil)) {
      throw StateError('runtime_queue_timeout');
    }

    final folder = Directory('${root.path}/$hash');
    final manifestFile = File('${folder.path}/drpy.json');
    if (!await manifestFile.exists()) throw StateError('bundle_missing');
    final stat = await manifestFile.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > _maxBundleBytes) {
      throw StateError('bundle_size');
    }
    final bytes = await manifestFile.readAsBytes();
    if (sha256.convert(bytes).toString() != hash) {
      throw StateError('bundle_changed');
    }
    final manifest = _validateDrpyManifest(
      jsonDecode(utf8.decode(bytes)),
    );
    final sourceId = manifest['sourceId'] as String;

    // Never run two stale copies against the same persistent state file.
    for (final entry in _workers.entries.toList()) {
      if (entry.value.sourceId != sourceId) continue;
      if (entry.value.activeCalls > 0) throw StateError('drpy_source_busy');
      _workers.remove(entry.key);
      await _stopWorker(entry.value);
    }

    if ((_releases[hash] ?? 0) != epoch || _closing || _resetting) {
      throw StateError('bundle_released');
    }

    final stateDir = Directory('${root.path}/drpy-state/$sourceId');
    await stateDir.create(recursive: true);

    final workerId = _syncHttp.nextWorkerId();
    _syncHttp.registerManifest(workerId, manifest);
    final publicProxyBase = '${base.toString()}/$hash/proxy?do=js';

    final handle = await _DrpyWorkerHandle.spawn(
      hash: hash,
      workerId: workerId,
      sourceId: sourceId,
      rootPath: root.path,
      stateDirPath: stateDir.path,
      manifest: manifest,
      publicProxyBase: publicProxyBase,
      syncHttpPort: _syncHttp.port,
      syncHttpSecret: _syncHttp.secret,
      onExit: (h) {
        _syncHttp.cancelWorker(h.workerId);
        _syncHttp.unregisterManifest(h.workerId);
        if (identical(_workers[hash], h)) _workers.remove(hash);
      },
    );
    _workers[hash] = handle;
    return handle;
  }

  Future<void> _handleDrpyCall(
    HttpRequest req,
    HttpResponse res,
    String hash,
  ) async {
    Map<String, Object?> call;
    try {
      final body = await _readRequestBytes(req, _maxResultBytes);
      call = _validateDrpyCall(jsonDecode(utf8.decode(body)));
    } catch (_) {
      _respondJson(res, 400, {'error': 'drpy_call'});
      return;
    }

    _DrpyWorkerHandle worker;
    try {
      worker = await _loadDrpyWorker(hash);
    } catch (_) {
      _respondJson(res, 503, {'error': 'source_runtime_unavailable'});
      return;
    }

    worker.activeCalls++;
    worker.lastUsed = DateTime.now();
    var responded = false;
    var clientDisconnected = false;
    unawaited(
      res.done.whenComplete(() {
        if (!responded) {
          clientDisconnected = true;
          _syncHttp.cancelWorker(worker.workerId);
        }
      }),
    );

    try {
      final result = await worker.invoke(
        method: call['method'] as String,
        args: (call['args'] as List).cast<Object?>(),
        isProxy: false,
        onTimeoutOrCancel: () {
          _syncHttp.cancelWorker(worker.workerId);
        },
      );
      if (clientDisconnected) return;
      responded = true;
      if (result.error != null) {
        _respondJson(res, 422, {'error': result.error!});
        return;
      }
      if (result.usedProxy) {
        worker.playedAt = DateTime.now();
      }
      res.statusCode = 200;
      res.headers.contentType = ContentType.json;
      res.headers.set('Cache-Control', 'no-store');
      res.write(result.rawJson!);
      await res.close();
    } catch (_) {
      if (!clientDisconnected) {
        responded = true;
        _respondJson(res, 422, {'error': 'drpy_source_failed'});
      }
    } finally {
      worker.activeCalls--;
      if (clientDisconnected && worker.activeCalls == 0) {
        if (identical(_workers[hash], worker)) _workers.remove(hash);
        unawaited(_stopWorker(worker));
      }
    }
  }

  Future<void> _handleDrpyProxy(
    HttpRequest req,
    HttpResponse res,
    String hash,
  ) async {
    _DrpyWorkerHandle worker;
    try {
      worker = await _loadDrpyWorker(hash);
    } catch (_) {
      _respondJson(res, 503, {'error': 'source_runtime_unavailable'});
      return;
    }

    worker.activeCalls++;
    worker.lastUsed = DateTime.now();
    worker.playedAt = DateTime.now();
    try {
      final params = <String, String>{};
      req.uri.queryParameters.forEach((k, v) => params[k] = v);
      final result = await worker.invoke(
        method: 'proxy',
        args: [params],
        isProxy: true,
        onTimeoutOrCancel: () {
          _syncHttp.cancelWorker(worker.workerId);
        },
      );
      if (result.error != null) {
        _respondJson(res, 422, {'error': result.error!});
        return;
      }
      final decoded = jsonDecode(result.rawJson!);
      if (decoded is! List ||
          decoded.length != 3 ||
          decoded[0] is! int ||
          (decoded[0] as int) < 200 ||
          (decoded[0] as int) > 599 ||
          decoded[1] is! String ||
          (decoded[1] as String).length > 256 ||
          RegExp(r'[\r\n\x00]').hasMatch(decoded[1] as String)) {
        _respondJson(res, 422, {'error': 'drpy_proxy_result'});
        return;
      }
      var status = decoded[0] as int;
      final contentType = decoded[1] as String;
      final payload = decoded[2];
      Uint8List bytes;
      if (payload is String) {
        bytes = Uint8List.fromList(utf8.encode(payload));
      } else if (payload is List &&
          payload.every((v) => v is int && v >= 0 && v <= 255)) {
        bytes = Uint8List.fromList(payload.cast<int>());
      } else {
        _respondJson(res, 422, {'error': 'drpy_proxy_result'});
        return;
      }
      if (bytes.length > _maxResultBytes) {
        _respondJson(res, 422, {'error': 'drpy_proxy_result'});
        return;
      }

      final isText = RegExp(
        r'^text\/|json|mpegurl',
        caseSensitive: false,
      ).hasMatch(contentType);
      res.headers.set('Content-Type', contentType);
      res.headers.set('Cache-Control', 'no-store');
      res.headers.set('Accept-Ranges', isText ? 'none' : 'bytes');

      final rangeHeader = req.headers.value('range');
      if (rangeHeader != null && status == 200 && !isText) {
        final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader);
        int? start;
        int? end;
        if (m != null) {
          final s1 = m.group(1)!;
          final s2 = m.group(2)!;
          if (s1.isNotEmpty) {
            start = int.tryParse(s1);
            end = s2.isNotEmpty
                ? min(bytes.length - 1, int.tryParse(s2) ?? -1)
                : bytes.length - 1;
          } else if (s2.isNotEmpty) {
            final suffix = int.tryParse(s2);
            if (suffix != null) {
              start = max(0, bytes.length - suffix);
              end = bytes.length - 1;
            }
          }
        }
        if (start == null ||
            end == null ||
            start < 0 ||
            start > end ||
            start >= bytes.length) {
          res.statusCode = 416;
          res.headers.set('Content-Range', 'bytes */${bytes.length}');
          await res.close();
          return;
        }
        res.headers.set('Content-Range', 'bytes $start-$end/${bytes.length}');
        bytes = Uint8List.sublistView(bytes, start, end + 1);
        status = 206;
      }

      res.statusCode = status;
      res.headers.contentLength = bytes.length;
      if (req.method != 'HEAD') {
        res.add(bytes);
      }
      await res.close();
    } catch (_) {
      _respondJson(res, 422, {'error': 'drpy_source_failed'});
    } finally {
      worker.activeCalls--;
    }
  }

  static Map<String, Object?> _validateDrpyManifest(Object? value) {
    const allowed = {
      'kind',
      'version',
      'runtime',
      'sourceId',
      'origin',
      'rule',
      'headers',
      'requestTimeoutMs',
      'modules',
    };
    if (value is! Map ||
        value.keys.any((k) => !allowed.contains(k)) ||
        value['kind'] != 'drpy' ||
        value['version'] != 1 ||
        value['runtime'] != drpyRuntime ||
        value['sourceId'] is! String ||
        !_hashPattern.hasMatch(value['sourceId'] as String) ||
        value['rule'] is! String ||
        (value['rule'] as String).trim().isEmpty ||
        utf8.encode(value['rule'] as String).length > _maxResultBytes) {
      throw const FormatException('drpy_manifest');
    }
    final originStr = value['origin'];
    final origin = originStr is String ? Uri.tryParse(originStr) : null;
    if (origin == null ||
        !const ['http', 'https', 'pkg'].contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasFragment) {
      throw const FormatException('drpy_origin');
    }
    final rawModules = value['modules'] ?? <String, Object?>{};
    if (rawModules is! Map || rawModules.length > 32) {
      throw const FormatException('drpy_modules');
    }
    final modules = <String, String>{};
    var moduleBytes = 0;
    for (final entry in rawModules.entries) {
      final k = entry.key;
      final v = entry.value;
      final uri = k is String ? Uri.tryParse(k) : null;
      if (origin.scheme != 'pkg' ||
          uri == null ||
          uri.scheme != 'pkg' ||
          uri.host != origin.host ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          k is! String ||
          k.length > 8192 ||
          v is! String ||
          (moduleBytes += utf8.encode(v).length) > _maxResultBytes) {
        throw const FormatException('drpy_modules');
      }
      modules[k] = v;
    }
    final rawHeaders = value['headers'];
    if (rawHeaders is! Map || rawHeaders.length > 64) {
      throw const FormatException('drpy_headers');
    }
    final headers = <String, String>{};
    for (final entry in rawHeaders.entries) {
      final k = entry.key;
      final v = entry.value;
      if (k is! String ||
          v is! String ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(k) ||
          v.length > 8192 ||
          RegExp(r'[\r\n\x00]').hasMatch(v) ||
          const [
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
          ].contains(k.toLowerCase())) {
        throw const FormatException('drpy_headers');
      }
      headers[k] = v;
    }
    final timeout = value['requestTimeoutMs'] ?? 10000;
    if (timeout is! int || timeout < 100 || timeout > 15000) {
      throw const FormatException('drpy_timeout');
    }
    return {
      'kind': 'drpy',
      'version': 1,
      'runtime': drpyRuntime,
      'sourceId': value['sourceId'] as String,
      'origin': originStr,
      'rule': value['rule'] as String,
      'headers': headers,
      'modules': modules,
      'requestTimeoutMs': timeout,
    };
  }

  static Map<String, Object?> _validateDrpyCall(Object? value) {
    if (value is! Map ||
        value.keys.any((k) => !const {'version', 'method', 'args'}.contains(k)) ||
        value['version'] != 1 ||
        value['args'] is! List) {
      throw const FormatException('drpy_call');
    }
    final method = value['method'];
    final a = value['args'] as List;
    bool isText(Object? v) => v is String && v.length <= 256 * 1024;
    bool isPage(Object? v) => v is int && v > 0 && v < 1000000;
    var ok = false;
    switch (method) {
      case 'home':
        ok = a.length == 1 && a[0] is bool;
        break;
      case 'homeVod':
        ok = a.isEmpty;
        break;
      case 'category':
        ok = a.length == 4 &&
            isText(a[0]) &&
            isPage(a[1]) &&
            a[2] is bool &&
            a[3] is Map;
        break;
      case 'search':
        ok = a.length == 3 && isText(a[0]) && a[1] is bool && isPage(a[2]);
        break;
      case 'detail':
        ok = a.length == 1 && isText(a[0]);
        break;
      case 'play':
        ok = a.length == 3 &&
            isText(a[0]) &&
            isText(a[1]) &&
            a[2] is List &&
            (a[2] as List).every(isText);
        break;
      case 'action':
        ok = a.length == 1 && isText(a[0]);
        break;
    }
    if (!ok) throw const FormatException('drpy_method_arguments');
    return {'version': 1, 'method': method as String, 'args': a};
  }
}

class _BootstrapTask {
  bool cancelled = false;
  void Function()? onCancel;
  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  void cancel() {
    cancelled = true;
    onCancel?.call();
  }

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _DrpyCallResult {
  final String? rawJson;
  final String? error;
  final bool usedProxy;
  const _DrpyCallResult({this.rawJson, this.error, this.usedProxy = false});
}

class _DrpyWorkerHandle {
  final String hash;
  final int workerId;
  final String sourceId;
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _exitPort;

  int activeCalls = 0;
  DateTime lastUsed = DateTime.now();
  DateTime? playedAt;
  bool disposed = false;
  Future<void> _serialQueue = Future<void>.value();

  _DrpyWorkerHandle._({
    required this.hash,
    required this.workerId,
    required this.sourceId,
    required Isolate isolate,
    required SendPort sendPort,
    required ReceivePort exitPort,
  }) : _isolate = isolate,
       _sendPort = sendPort,
       _exitPort = exitPort;

  static Future<_DrpyWorkerHandle> spawn({
    required String hash,
    required int workerId,
    required String sourceId,
    required String rootPath,
    required String stateDirPath,
    required Map<String, Object?> manifest,
    required String publicProxyBase,
    required int syncHttpPort,
    required String syncHttpSecret,
    required void Function(_DrpyWorkerHandle) onExit,
  }) async {
    final handshakePort = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _drpyWorkerIsolateEntry,
      [
        handshakePort.sendPort,
        workerId,
        rootPath,
        stateDirPath,
        manifest,
        publicProxyBase,
        syncHttpPort,
        syncHttpSecret,
      ],
      onExit: exitPort.sendPort,
    );
    try {
      final first = await handshakePort.first.timeout(
        const Duration(seconds: 15),
      );
      handshakePort.close();
      if (first is! List || first.length != 2 || first[0] != true) {
        throw StateError('bundle_start_failed');
      }
      final sendPort = first[1] as SendPort;
      final handle = _DrpyWorkerHandle._(
        hash: hash,
        workerId: workerId,
        sourceId: sourceId,
        isolate: isolate,
        sendPort: sendPort,
        exitPort: exitPort,
      );
      exitPort.listen((_) {
        handle.disposed = true;
        exitPort.close();
        onExit(handle);
      });
      return handle;
    } catch (_) {
      handshakePort.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<_DrpyCallResult> invoke({
    required String method,
    required List<Object?> args,
    required bool isProxy,
    required void Function() onTimeoutOrCancel,
  }) {
    final completer = Completer<_DrpyCallResult>();
    _serialQueue = _serialQueue.then((_) async {
      if (disposed) {
        completer.complete(const _DrpyCallResult(error: 'drpy_source_failed'));
        return;
      }
      final replyPort = ReceivePort();
      final timer = Timer(const Duration(milliseconds: 21000), () {
        onTimeoutOrCancel();
        unawaited(dispose());
        if (!completer.isCompleted) {
          completer.complete(
            const _DrpyCallResult(error: 'drpy_execution_timeout'),
          );
        }
      });
      try {
        _sendPort.send(['call', replyPort.sendPort, method, args, isProxy]);
        final reply = await replyPort.first.timeout(
          const Duration(milliseconds: 21500),
        );
        if (!completer.isCompleted) {
          if (reply is List && reply.length >= 2) {
            if (reply[0] == true) {
              completer.complete(
                _DrpyCallResult(
                  rawJson: reply[1] as String,
                  usedProxy: reply.length >= 3 && reply[2] == true,
                ),
              );
            } else {
              completer.complete(
                _DrpyCallResult(error: reply[1]?.toString() ?? 'drpy_source_failed'),
              );
            }
          } else {
            completer.complete(
              const _DrpyCallResult(error: 'drpy_source_failed'),
            );
          }
        }
      } on TimeoutException {
        onTimeoutOrCancel();
        await dispose();
        if (!completer.isCompleted) {
          completer.complete(
            const _DrpyCallResult(error: 'drpy_execution_timeout'),
          );
        }
      } catch (_) {
        if (!completer.isCompleted) {
          completer.complete(
            const _DrpyCallResult(error: 'drpy_source_failed'),
          );
        }
      } finally {
        timer.cancel();
        replyPort.close();
      }
    });
    return completer.future;
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    try {
      final ack = ReceivePort();
      _sendPort.send(['close', ack.sendPort]);
      await ack.first.timeout(const Duration(milliseconds: 200));
      ack.close();
    } catch (_) {}
    _isolate.kill(priority: Isolate.immediate);
    _exitPort.close();
  }
}

// =============================================================================
// Main-Isolate Synchronous HTTP Bridge for DRPY Worker Isolates
// =============================================================================

/// Allows DRPY worker isolates to execute synchronous `req(url, options)` via
/// `RawSynchronousSocket.connectSync` against this loopback TCP server while
/// the main isolate executes full async `HttpClient` requests (TLS, redirects,
/// timeouts, cancellation, streaming size caps).
class _SyncHttpBridge {
  static const int _maxResultBytes = 6 * 1024 * 1024;
  static const int _maxFrameBytes = 8 * 1024 * 1024;

  final ServerSocket _server;
  final String secret;
  final Map<int, Map<String, Object?>> _manifests = {};
  final Map<int, Set<_ActiveSyncRequest>> _activeByWorker = {};
  int _workerSeq = 0;

  int get port => _server.port;

  _SyncHttpBridge._(this._server, this.secret) {
    _server.listen(_handleConnection, onError: (_) {});
  }

  static Future<_SyncHttpBridge> start() async {
    final secretBytes = CatPawCrypto.randomBytes(16);
    final secret = secretBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _SyncHttpBridge._(server, secret);
  }

  int nextWorkerId() => ++_workerSeq;

  void registerManifest(int workerId, Map<String, Object?> manifest) {
    _manifests[workerId] = manifest;
  }

  void unregisterManifest(int workerId) {
    _manifests.remove(workerId);
  }

  void cancelWorker(int workerId) {
    final active = _activeByWorker.remove(workerId);
    if (active == null) return;
    for (final req in active.toList()) {
      req.cancel();
    }
  }

  Future<void> close() async {
    for (final id in _activeByWorker.keys.toList()) {
      cancelWorker(id);
    }
    _manifests.clear();
    try {
      await _server.close();
    } catch (_) {}
  }

  void _handleConnection(Socket socket) {
    final buffer = BytesBuilder(copy: false);
    int? expectedLength;
    var dispatched = false;
    StreamSubscription<Uint8List>? sub;

    void sendResponse(Map<String, Object?> payload) {
      try {
        final encoded = utf8.encode(jsonEncode(payload));
        final header = ByteData(4)..setUint32(0, encoded.length, Endian.big);
        socket.add(header.buffer.asUint8List());
        socket.add(encoded);
        unawaited(
          socket.flush().then((_) => socket.close()).catchError((_) {
            socket.destroy();
          }),
        );
      } catch (_) {
        socket.destroy();
      }
    }

    sub = socket.listen(
      (chunk) {
        if (dispatched) return;
        buffer.add(chunk);
        if (expectedLength == null && buffer.length >= 36) {
          final current = buffer.toBytes();
          final gotSecret = ascii.decode(current.sublist(0, 32));
          if (gotSecret != secret) {
            dispatched = true;
            sub?.cancel();
            socket.destroy();
            return;
          }
          expectedLength = ByteData.sublistView(
            current,
            32,
            36,
          ).getUint32(0, Endian.big);
          if (expectedLength! <= 0 || expectedLength! > _maxFrameBytes) {
            dispatched = true;
            sub?.cancel();
            socket.destroy();
            return;
          }
        }
        if (expectedLength != null && buffer.length >= 36 + expectedLength!) {
          dispatched = true;
          sub?.cancel();
          final all = buffer.takeBytes();
          final payloadBytes = Uint8List.sublistView(
            all,
            36,
            36 + expectedLength!,
          );
          unawaited(_executeHttp(payloadBytes, socket, sendResponse));
        }
      },
      onError: (_) => socket.destroy(),
      onDone: () {
        if (!dispatched) socket.destroy();
      },
      cancelOnError: true,
    );
  }

  Future<void> _executeHttp(
    Uint8List payloadBytes,
    Socket socket,
    void Function(Map<String, Object?>) sendResponse,
  ) async {
    int? workerId;
    _ActiveSyncRequest? active;
    try {
      final msg = jsonDecode(utf8.decode(payloadBytes));
      if (msg is! Map) {
        sendResponse({'error': 'drpy_http_request'});
        return;
      }
      workerId = msg['workerId'] as int?;
      final manifest = workerId != null ? _manifests[workerId] : null;
      if (manifest == null) {
        sendResponse({'error': 'drpy_http_request'});
        return;
      }
      final urlText = msg['url']?.toString() ?? '';
      final options = msg['options'] is Map
          ? Map<String, Object?>.from(msg['options'] as Map)
          : <String, Object?>{};
      final sourceEncoding = msg['sourceEncoding']?.toString() ?? '';
      final deadlineMs = (msg['deadline'] as num?)?.toInt() ?? 0;
      final remainingMs = deadlineMs - DateTime.now().millisecondsSinceEpoch;
      final defaultTimeout = (manifest['requestTimeoutMs'] as int?) ?? 10000;
      final optTimeout = (options['timeout'] as num?)?.toInt() ?? defaultTimeout;
      final durationMs = min(min(max(optTimeout, 100), 15000), remainingMs);
      if (durationMs <= 0) {
        sendResponse({'error': 'drpy_http_timeout'});
        return;
      }

      final originUri = Uri.parse(manifest['origin'] as String);
      var targetUri = originUri.resolve(urlText);
      final inputHeaders = <String, Object?>{};
      if (_sameOrigin(targetUri, originUri)) {
        final mh = manifest['headers'] as Map<String, String>;
        inputHeaders.addAll(mh);
      }
      final optHeaders = options['headers'];
      if (optHeaders is Map) {
        optHeaders.forEach((k, v) {
          inputHeaders[k.toString()] = v;
        });
      }
      final headers = <String, String>{};
      for (final entry in inputHeaders.entries) {
        final key = entry.key;
        final val = entry.value;
        if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(key) ||
            val is! String ||
            RegExp(r'[\r\n\x00]').hasMatch(val) ||
            val.length > 8192) {
          sendResponse({'error': 'drpy_http_headers'});
          return;
        }
        final lower = key.toLowerCase();
        if (!const {
          'host',
          'connection',
          'content-length',
          'transfer-encoding',
          'accept-encoding',
        }.contains(lower)) {
          headers[lower] = val;
        }
      }
      headers['accept-encoding'] = 'identity';
      if (targetUri.userInfo.isNotEmpty) {
        if (!headers.containsKey('authorization')) {
          headers['authorization'] =
              'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(targetUri.userInfo)))}';
        }
        targetUri = targetUri.replace(userInfo: '');
      }

      var method = (options['method']?.toString() ?? 'GET').toUpperCase();
      if (!const {
        'GET',
        'POST',
        'HEAD',
        'PUT',
        'PATCH',
        'DELETE',
        'OPTIONS',
      }.contains(method)) {
        sendResponse({'error': 'drpy_http_method'});
        return;
      }

      Object? rawBody = options.containsKey('body')
          ? options['body']
          : options['data'];
      String? bodyStr;
      if (rawBody != null) {
        bodyStr = rawBody is String ? rawBody : jsonEncode(rawBody);
      }
      Uint8List? bodyBytes =
          bodyStr != null && method != 'GET' && method != 'HEAD'
          ? Uint8List.fromList(utf8.encode(bodyStr))
          : null;
      if (bodyBytes != null && bodyBytes.length > _maxResultBytes) {
        sendResponse({'error': 'drpy_http_body_too_large'});
        return;
      }

      final client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = Duration(milliseconds: min(durationMs, 8000));
      active = _ActiveSyncRequest(client: client, socket: socket);
      _activeByWorker.putIfAbsent(workerId!, () => {}).add(active);

      var timedOut = false;
      final timer = Timer(Duration(milliseconds: durationMs), () {
        timedOut = true;
        client.close(force: true);
      });

      try {
        final followRedirects =
            options['redirect'] != 0 && options['redirect'] != false;
        var currentUri = targetUri;
        var currentMethod = method;
        var currentBody = bodyBytes;
        var redirects = 0;

        while (true) {
          if (currentUri.scheme != 'http' && currentUri.scheme != 'https') {
            sendResponse({'error': 'drpy_http_protocol'});
            return;
          }
          if (currentUri.userInfo.isNotEmpty) {
            sendResponse({'error': 'drpy_redirect_credentials'});
            return;
          }
          final httpReq = await client.openUrl(currentMethod, currentUri);
          httpReq.followRedirects = false;
          headers.forEach((k, v) => httpReq.headers.set(k, v));
          if (currentBody != null) {
            httpReq.contentLength = currentBody.length;
            httpReq.add(currentBody);
          }
          final httpResp = await httpReq.close();
          final statusCode = httpResp.statusCode;
          final location = httpResp.headers.value('location');

          if (followRedirects &&
              const {301, 302, 303, 307, 308}.contains(statusCode) &&
              location != null &&
              location.isNotEmpty) {
            await httpResp.drain<void>();
            if (redirects >= 5) {
              sendResponse({'error': 'drpy_http_redirect_limit'});
              return;
            }
            Uri nextUri;
            try {
              nextUri = currentUri.resolve(location);
            } catch (_) {
              sendResponse({'error': 'drpy_http_redirect'});
              return;
            }
            if (!_sameOrigin(nextUri, currentUri)) {
              headers.remove('authorization');
              headers.remove('cookie');
              headers.remove('cookie2');
              headers.remove('proxy-authorization');
            }
            if ((statusCode == 303 && currentMethod != 'HEAD') ||
                ((statusCode == 301 || statusCode == 302) &&
                    currentMethod == 'POST')) {
              currentMethod = 'GET';
              currentBody = null;
              headers.remove('content-type');
              headers.remove('content-length');
            }
            currentUri = nextUri;
            redirects++;
            continue;
          }

          final rawChunks = BytesBuilder(copy: false);
          await for (final chunk in httpResp) {
            if (rawChunks.length + chunk.length > _maxResultBytes) {
              sendResponse({'error': 'drpy_http_response_too_large'});
              return;
            }
            rawChunks.add(chunk);
          }
          var bytes = rawChunks.takeBytes();
          final contentEncoding =
              (httpResp.headers.value('content-encoding') ?? '').toLowerCase();
          if (contentEncoding == 'gzip') {
            bytes = CatPawCrypto.zlibInflate(
              'gunzip',
              bytes,
              maxOutputLength: _maxResultBytes,
            );
          } else if (contentEncoding == 'deflate') {
            bytes = CatPawCrypto.zlibInflate(
              'inflate',
              bytes,
              maxOutputLength: _maxResultBytes,
            );
          }

          final responseHeaders = <String, String>{};
          httpResp.headers.forEach((name, values) {
            responseHeaders[name.toLowerCase()] = values.join('\n');
          });

          final contentType = responseHeaders['content-type'] ?? '';
          final charsetMatch = RegExp(
            r'''charset\s*=\s*["']?([^;\s"']+)''',
            caseSensitive: false,
          ).firstMatch(contentType);
          final charset = (options['encoding']?.toString().isNotEmpty == true
                  ? options['encoding'].toString()
                  : (charsetMatch?.group(1) ??
                        (sourceEncoding.isNotEmpty ? sourceEncoding : 'utf-8')))
              .trim();

          if (options['buffer'] == 2) {
            sendResponse({
              'code': statusCode,
              'content': base64Encode(bytes),
              'headers': responseHeaders,
              'url': currentUri.toString(),
            });
            return;
          }

          final label = charset
              .toLowerCase()
              .replaceAll('-', '')
              .replaceAll('_', '');
          if (const {
            'gbk',
            'gb2312',
            'gb231280',
            'csgb2312',
            'csiso58gb231280',
            'chinese',
            'isoir58',
            'xgbk',
            'cp936',
            'ms936',
            'windows936',
            'gb18030',
            'big5',
            'big5hkscs',
            'cnbig5',
            'csbig5',
            'xxbig5',
            'cp950',
            'windows950',
          }.contains(label)) {
            sendResponse({
              'code': statusCode,
              'contentB64': base64Encode(bytes),
              'charset': charset,
              'headers': responseHeaders,
              'url': currentUri.toString(),
            });
            return;
          }

          String content;
          try {
            content = _decodeStandardCharset(bytes, label);
          } catch (_) {
            sendResponse({'error': 'drpy_http_encoding'});
            return;
          }

          sendResponse({
            'code': statusCode,
            'content': content,
            'headers': responseHeaders,
            'url': currentUri.toString(),
          });
          return;
        }
      } catch (error) {
        if (timedOut) {
          sendResponse({'error': 'drpy_http_timeout'});
        } else if (error is FormatException &&
            error.message.startsWith('drpy_')) {
          sendResponse({'error': error.message});
        } else if (error is SocketException ||
            error is HandshakeException ||
            error is TlsException) {
          sendResponse({'error': 'drpy_http_connection_failed'});
        } else {
          sendResponse({'error': 'drpy_http_response_failed'});
        }
      } finally {
        timer.cancel();
        client.close(force: true);
      }
    } catch (_) {
      sendResponse({'error': 'drpy_http_request'});
    } finally {
      if (workerId != null && active != null) {
        _activeByWorker[workerId]?.remove(active);
      }
    }
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  static String _decodeStandardCharset(Uint8List bytes, String normalizedLabel) {
    if (normalizedLabel.isEmpty ||
        normalizedLabel == 'utf8' ||
        normalizedLabel == 'unicode11utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (normalizedLabel == 'latin1' ||
        normalizedLabel == 'iso88591' ||
        normalizedLabel == 'windows1252' ||
        normalizedLabel == 'ascii' ||
        normalizedLabel == 'usascii') {
      return latin1.decode(bytes);
    }
    if (normalizedLabel == 'utf16le' || normalizedLabel == 'ucs2') {
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
    if (normalizedLabel == 'utf16be') {
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    throw const FormatException('drpy_http_encoding');
  }
}

class _ActiveSyncRequest {
  final HttpClient client;
  final Socket socket;
  _ActiveSyncRequest({required this.client, required this.socket});
  void cancel() {
    client.close(force: true);
    socket.destroy();
  }
}

// =============================================================================
// Shared QuickJS-NG Compatibility Prelude (Buffer, URL, TextEncoder/Decoder)
// =============================================================================

const String _quickJsCompatPrelude = r'''
globalThis.global = globalThis;
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.navigator = { appName: 'Netscape' };
globalThis.console = { log(){}, info(){}, warn(){}, error(){}, debug(){} };
globalThis.print = globalThis.log = function(){};
globalThis.process = {
  env: {},
  versions: { node: '20.0.0' },
  nextTick(fn) { Promise.resolve().then(fn); },
};

(function() {
  const B64_ALPHA = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const B64_LOOKUP = new Int16Array(128).fill(-1);
  for (let i = 0; i < B64_ALPHA.length; i++) B64_LOOKUP[B64_ALPHA.charCodeAt(i)] = i;
  B64_LOOKUP['-'.charCodeAt(0)] = 62;
  B64_LOOKUP['_'.charCodeAt(0)] = 63;

  function encodeUtf8(str) {
    const out = [];
    for (let i = 0; i < str.length; i++) {
      let c = str.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          c = ((c - 0xd800) << 10) + (next - 0xdc00) + 0x10000;
          i++;
        }
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return new Uint8Array(out);
  }

  function decodeUtf8(bytes, fatal) {
    const chunks = [];
    let part = '';
    const flush = () => { if (part.length >= 4096) { chunks.push(part); part = ''; } };
    for (let i = 0; i < bytes.length; ) {
      const b0 = bytes[i++];
      if (b0 < 0x80) {
        part += String.fromCharCode(b0);
      } else if ((b0 & 0xe0) === 0xc0) {
        if (i >= bytes.length) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; break; }
        const b1 = bytes[i++];
        if ((b1 & 0xc0) !== 0x80) { if (fatal) throw new TypeError('Invalid UTF-8'); i--; part += '\ufffd'; continue; }
        const cp = ((b0 & 0x1f) << 6) | (b1 & 0x3f);
        if (cp < 0x80) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; }
        else part += String.fromCharCode(cp);
      } else if ((b0 & 0xf0) === 0xe0) {
        if (i + 1 >= bytes.length) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; break; }
        const b1 = bytes[i++], b2 = bytes[i++];
        if ((b1 & 0xc0) !== 0x80 || (b2 & 0xc0) !== 0x80) { if (fatal) throw new TypeError('Invalid UTF-8'); i -= 2; part += '\ufffd'; continue; }
        const cp = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f);
        if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff)) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; }
        else part += String.fromCharCode(cp);
      } else if ((b0 & 0xf8) === 0xf0) {
        if (i + 2 >= bytes.length) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; break; }
        const b1 = bytes[i++], b2 = bytes[i++], b3 = bytes[i++];
        if ((b1 & 0xc0) !== 0x80 || (b2 & 0xc0) !== 0x80 || (b3 & 0xc0) !== 0x80) { if (fatal) throw new TypeError('Invalid UTF-8'); i -= 3; part += '\ufffd'; continue; }
        const cp = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (cp < 0x10000 || cp > 0x10ffff) { if (fatal) throw new TypeError('Invalid UTF-8'); part += '\ufffd'; }
        else {
          const v = cp - 0x10000;
          part += String.fromCharCode(0xd800 | (v >> 10), 0xdc00 | (v & 0x3ff));
        }
      } else {
        if (fatal) throw new TypeError('Invalid UTF-8');
        part += '\ufffd';
      }
      flush();
    }
    chunks.push(part);
    return chunks.join('');
  }

  function encodeBase64(bytes) {
    const chunks = [];
    let part = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0, c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      part += B64_ALPHA[a >> 2] + B64_ALPHA[((a & 3) << 4) | (b >> 4)] +
        (i + 1 < bytes.length ? B64_ALPHA[((b & 15) << 2) | (c >> 6)] : '=') +
        (i + 2 < bytes.length ? B64_ALPHA[c & 63] : '=');
      if (part.length >= 4096) { chunks.push(part); part = ''; }
    }
    chunks.push(part);
    return chunks.join('');
  }

  function decodeBase64(str) {
    const clean = String(str).replace(/[^A-Za-z0-9+/=_-]/g, '');
    const out = [];
    let bits = 0, count = 0;
    for (let i = 0; i < clean.length; i++) {
      const ch = clean.charCodeAt(i);
      if (ch === 61) break; // '='
      const v = ch < 128 ? B64_LOOKUP[ch] : -1;
      if (v < 0) continue;
      bits = (bits << 6) | v;
      count += 6;
      if (count >= 8) {
        count -= 8;
        out.push((bits >> count) & 0xff);
      }
    }
    return new Uint8Array(out);
  }

  function encodeHex(bytes) {
    const HEX = '0123456789abcdef';
    const chunks = [];
    let part = '';
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      part += HEX[b >> 4] + HEX[b & 15];
      if (part.length >= 4096) { chunks.push(part); part = ''; }
    }
    chunks.push(part);
    return chunks.join('');
  }

  function decodeHex(str) {
    const s = String(str);
    const len = s.length >> 1;
    const out = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      const hi = parseInt(s[i * 2], 16);
      const lo = parseInt(s[i * 2 + 1], 16);
      if (Number.isNaN(hi) || Number.isNaN(lo)) return out.subarray(0, i);
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  function encodeString(str, encoding) {
    const enc = String(encoding || 'utf8').toLowerCase().replace('-', '');
    if (enc === 'utf8') return encodeUtf8(str);
    if (enc === 'latin1' || enc === 'binary' || enc === 'ascii') {
      const out = new Uint8Array(str.length);
      for (let i = 0; i < str.length; i++) out[i] = str.charCodeAt(i) & 0xff;
      return out;
    }
    if (enc === 'hex') return decodeHex(str);
    if (enc === 'base64' || enc === 'base64url') return decodeBase64(str);
    if (enc === 'utf16le' || enc === 'ucs2') {
      const out = new Uint8Array(str.length * 2);
      for (let i = 0; i < str.length; i++) {
        const c = str.charCodeAt(i);
        out[i * 2] = c & 0xff;
        out[i * 2 + 1] = c >> 8;
      }
      return out;
    }
    return encodeUtf8(str);
  }

  class Buffer extends Uint8Array {
    static isBuffer(v) { return v instanceof Buffer; }
    static alloc(size, fill, encoding) {
      const b = new Buffer(size >>> 0);
      if (fill !== undefined && fill !== 0) b.fill(fill, 0, b.length, encoding);
      return b;
    }
    static allocUnsafe(size) { return new Buffer(size >>> 0); }
    static allocUnsafeSlow(size) { return new Buffer(size >>> 0); }
    static byteLength(val, encoding) {
      if (typeof val === 'string') return encodeString(val, encoding).length;
      if (val && typeof val.byteLength === 'number') return val.byteLength;
      return 0;
    }
    static concat(list, totalLength) {
      if (!Array.isArray(list)) throw new TypeError('list must be an array');
      let len = totalLength;
      if (len === undefined) {
        len = 0;
        for (let i = 0; i < list.length; i++) len += list[i].length;
      }
      const out = new Buffer(len);
      let offset = 0;
      for (let i = 0; i < list.length && offset < len; i++) {
        const item = list[i];
        const copyLen = Math.min(item.length, len - offset);
        out.set(item.subarray ? item.subarray(0, copyLen) : item.slice(0, copyLen), offset);
        offset += copyLen;
      }
      return out;
    }
    static from(value, encodingOrOffset, length) {
      if (typeof value === 'string') {
        const bytes = encodeString(value, encodingOrOffset);
        const b = new Buffer(bytes.length);
        b.set(bytes);
        return b;
      }
      if (value instanceof ArrayBuffer) {
        const off = encodingOrOffset || 0;
        const len = length !== undefined ? length : (value.byteLength - off);
        return new Buffer(value, off, len);
      }
      if (ArrayBuffer.isView(value)) {
        const view = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        const b = new Buffer(view.length);
        b.set(view);
        return b;
      }
      if (Array.isArray(value) || (value && typeof value.length === 'number')) {
        const b = new Buffer(value.length);
        for (let i = 0; i < value.length; i++) b[i] = value[i] & 0xff;
        return b;
      }
      throw new TypeError('Unsupported Buffer.from input');
    }
    subarray(start, end) {
      const view = super.subarray(start, end);
      return new Buffer(view.buffer, view.byteOffset, view.byteLength);
    }
    slice(start, end) {
      return this.subarray(start, end);
    }
    toString(encoding, start, end) {
      const s = start || 0;
      const e = end !== undefined ? end : this.length;
      const view = (s === 0 && e === this.length) ? this : super.subarray(s, e);
      const enc = String(encoding || 'utf8').toLowerCase().replace('-', '');
      if (enc === 'utf8') return decodeUtf8(view, false);
      if (enc === 'latin1' || enc === 'binary' || enc === 'ascii') {
        const chunks = [];
        let part = '';
        for (let i = 0; i < view.length; i++) {
          part += String.fromCharCode(enc === 'ascii' ? (view[i] & 0x7f) : view[i]);
          if (part.length >= 4096) { chunks.push(part); part = ''; }
        }
        chunks.push(part);
        return chunks.join('');
      }
      if (enc === 'hex') return encodeHex(view);
      if (enc === 'base64') return encodeBase64(view);
      if (enc === 'base64url') return encodeBase64(view).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      if (enc === 'utf16le' || enc === 'ucs2') {
        const chunks = [];
        let part = '';
        for (let i = 0; i + 1 < view.length; i += 2) {
          part += String.fromCharCode(view[i] | (view[i + 1] << 8));
          if (part.length >= 4096) { chunks.push(part); part = ''; }
        }
        chunks.push(part);
        return chunks.join('');
      }
      return decodeUtf8(view, false);
    }
    equals(other) {
      if (!other || typeof other.length !== 'number' || this.length !== other.length) return false;
      for (let i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
      return true;
    }
    copy(target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
      const src = super.subarray(sourceStart, sourceEnd);
      const len = Math.min(src.length, Math.max(0, target.length - targetStart));
      target.set(src.subarray(0, len), targetStart);
      return len;
    }
    write(str, offset = 0, length, encoding) {
      if (typeof offset === 'string') { encoding = offset; offset = 0; length = this.length; }
      else if (typeof length === 'string') { encoding = length; length = this.length - offset; }
      const bytes = encodeString(str, encoding);
      const maxLen = Math.min(bytes.length, length !== undefined ? length : this.length - offset, this.length - offset);
      this.set(bytes.subarray(0, maxLen), offset);
      return maxLen;
    }
    fill(value, offset = 0, end = this.length, encoding) {
      if (typeof value === 'string') {
        const bytes = encodeString(value, encoding);
        if (!bytes.length) return super.fill(0, offset, end);
        for (let i = offset; i < end; i++) this[i] = bytes[(i - offset) % bytes.length];
        return this;
      }
      if (value instanceof Uint8Array) {
        if (!value.length) return super.fill(0, offset, end);
        for (let i = offset; i < end; i++) this[i] = value[(i - offset) % value.length];
        return this;
      }
      return super.fill(value & 0xff, offset, end);
    }
    indexOf(val, byteOffset = 0, encoding) {
      let start = byteOffset < 0 ? Math.max(0, this.length + byteOffset) : byteOffset;
      if (typeof val === 'number') {
        const b = val & 0xff;
        for (let i = start; i < this.length; i++) if (this[i] === b) return i;
        return -1;
      }
      const needle = typeof val === 'string' ? encodeString(val, encoding) : val;
      if (!needle || needle.length === 0) return start <= this.length ? start : -1;
      const limit = this.length - needle.length;
      outer: for (let i = start; i <= limit; i++) {
        for (let j = 0; j < needle.length; j++) {
          if (this[i + j] !== needle[j]) continue outer;
        }
        return i;
      }
      return -1;
    }
    readUInt8(o = 0) { return this[o]; }
    readInt8(o = 0) { const v = this[o]; return v > 127 ? v - 256 : v; }
    readUInt16LE(o = 0) { return this[o] | (this[o + 1] << 8); }
    readUInt16BE(o = 0) { return (this[o] << 8) | this[o + 1]; }
    readInt16LE(o = 0) { const v = this.readUInt16LE(o); return v > 0x7fff ? v - 0x10000 : v; }
    readInt16BE(o = 0) { const v = this.readUInt16BE(o); return v > 0x7fff ? v - 0x10000 : v; }
    readUInt32LE(o = 0) { return ((this[o] | (this[o + 1] << 8) | (this[o + 2] << 16)) + this[o + 3] * 0x1000000); }
    readUInt32BE(o = 0) { return (this[o] * 0x1000000 + ((this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3])); }
    readInt32LE(o = 0) { return this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24); }
    readInt32BE(o = 0) { return (this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]; }
    writeUInt8(v, o = 0) { this[o] = v & 0xff; return o + 1; }
    writeUInt16LE(v, o = 0) { this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; return o + 2; }
    writeUInt16BE(v, o = 0) { this[o] = (v >>> 8) & 0xff; this[o + 1] = v & 0xff; return o + 2; }
    writeUInt32LE(v, o = 0) { this[o] = v & 0xff; this[o + 1] = (v >>> 8) & 0xff; this[o + 2] = (v >>> 16) & 0xff; this[o + 3] = (v >>> 24) & 0xff; return o + 4; }
    writeUInt32BE(v, o = 0) { this[o] = (v >>> 24) & 0xff; this[o + 1] = (v >>> 16) & 0xff; this[o + 2] = (v >>> 8) & 0xff; this[o + 3] = v & 0xff; return o + 4; }
  }
  for (const staticName of ['from', 'alloc', 'allocUnsafe', 'allocUnsafeSlow', 'isBuffer', 'concat', 'byteLength']) {
    const desc = Object.getOwnPropertyDescriptor(Buffer, staticName);
    if (desc) Object.defineProperty(Buffer, staticName, { ...desc, enumerable: true });
  }
  globalThis.Buffer = Buffer;

  globalThis.TextEncoder = class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(str = '') { return encodeUtf8(String(str)); }
  };
  globalThis.TextDecoder = class TextDecoder {
    constructor(encoding = 'utf-8', options = {}) {
      this.encoding = String(encoding || 'utf-8').toLowerCase();
      this.fatal = Boolean(options && options.fatal);
    }
    decode(input) {
      if (!input) return '';
      const bytes = input instanceof ArrayBuffer
        ? new Uint8Array(input)
        : ArrayBuffer.isView(input)
          ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
          : new Uint8Array(input);
      const enc = this.encoding.replace(/[-_]/g, '');
      if (enc === 'utf8') return decodeUtf8(bytes, this.fatal);
      if (enc === 'latin1' || enc === 'iso88591' || enc === 'ascii' || enc === 'windows1252') {
        return Buffer.from(bytes).toString('latin1');
      }
      if (enc === 'utf16le' || enc === 'ucs2') return Buffer.from(bytes).toString('utf16le');
      return decodeUtf8(bytes, this.fatal);
    }
  };

  globalThis.btoa = function(str) {
    return Buffer.from(String(str), 'latin1').toString('base64');
  };
  globalThis.atob = function(str) {
    return Buffer.from(String(str), 'base64').toString('latin1');
  };

  class URLSearchParams {
    constructor(init) {
      this._entries = [];
      this._onChange = null;
      if (typeof init === 'string') {
        const q = init.startsWith('?') ? init.slice(1) : init;
        if (q) {
          for (const part of q.split('&')) {
            if (!part) continue;
            const eq = part.indexOf('=');
            const k = eq >= 0 ? part.slice(0, eq) : part;
            const v = eq >= 0 ? part.slice(eq + 1) : '';
            this._entries.push([
              decodeURIComponent(k.replace(/\+/g, ' ')),
              decodeURIComponent(v.replace(/\+/g, ' ')),
            ]);
          }
        }
      } else if (init && typeof init === 'object') {
        if (Array.isArray(init)) {
          for (const pair of init) this._entries.push([String(pair[0]), String(pair[1])]);
        } else {
          for (const k of Object.keys(init)) this._entries.push([k, String(init[k])]);
        }
      }
    }
    _notify() { if (this._onChange) this._onChange(); }
    append(name, value) { this._entries.push([String(name), String(value)]); this._notify(); }
    delete(name) { const n = String(name); this._entries = this._entries.filter(e => e[0] !== n); this._notify(); }
    get(name) { const n = String(name); const f = this._entries.find(e => e[0] === n); return f ? f[1] : null; }
    getAll(name) { const n = String(name); return this._entries.filter(e => e[0] === n).map(e => e[1]); }
    has(name) { const n = String(name); return this._entries.some(e => e[0] === n); }
    set(name, value) {
      const n = String(name), v = String(value);
      let found = false;
      const next = [];
      for (const e of this._entries) {
        if (e[0] === n) { if (!found) { next.push([n, v]); found = true; } }
        else next.push(e);
      }
      if (!found) next.push([n, v]);
      this._entries = next;
      this._notify();
    }
    entries() { return this._entries[Symbol.iterator](); }
    keys() { return this._entries.map(e => e[0])[Symbol.iterator](); }
    values() { return this._entries.map(e => e[1])[Symbol.iterator](); }
    forEach(cb, thisArg) { for (const [k, v] of this._entries) cb.call(thisArg, v, k, this); }
    [Symbol.iterator]() { return this.entries(); }
    toString() {
      return this._entries.map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&');
    }
  }
  globalThis.URLSearchParams = URLSearchParams;

  class URL {
    constructor(input, base) {
      const parsed = JSON.parse(__nativeParseUrl(String(input), base !== undefined ? String(base) : ''));
      if (parsed.error) throw new TypeError(parsed.error);
      this.protocol = parsed.protocol;
      this.username = parsed.username;
      this.password = parsed.password;
      this.hostname = parsed.hostname;
      this.port = parsed.port;
      this.pathname = parsed.pathname;
      this._search = parsed.search;
      this.hash = parsed.hash;
      this.searchParams = new URLSearchParams(this._search);
      this.searchParams._onChange = () => {
        const s = this.searchParams.toString();
        this._search = s ? '?' + s : '';
      };
    }
    get search() { return this._search; }
    set search(v) {
      const s = String(v || '');
      this._search = !s ? '' : (s.startsWith('?') ? s : '?' + s);
      this.searchParams = new URLSearchParams(this._search);
      this.searchParams._onChange = () => {
        const qs = this.searchParams.toString();
        this._search = qs ? '?' + qs : '';
      };
    }
    get host() { return this.port ? this.hostname + ':' + this.port : this.hostname; }
    get origin() {
      if (this.protocol === 'http:' || this.protocol === 'https:' || this.protocol === 'pkg:') {
        return this.protocol + '//' + this.host;
      }
      return 'null';
    }
    get href() {
      let auth = '';
      if (this.username || this.password) {
        auth = this.username + (this.password ? ':' + this.password : '') + '@';
      }
      return this.protocol + '//' + auth + this.host + this.pathname + this._search + this.hash;
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
  }
  globalThis.URL = URL;
})();
''';

String _parseUrlForJs(String input, String base) {
  try {
    Uri uri;
    if (base.isNotEmpty) {
      final baseUri = Uri.parse(base);
      if (baseUri.scheme.isEmpty) {
        return jsonEncode({'error': 'Invalid base URL'});
      }
      uri = baseUri.resolve(input);
    } else {
      uri = Uri.parse(input);
    }
    if (uri.scheme.isEmpty) {
      return jsonEncode({'error': 'Invalid URL'});
    }
    final scheme = uri.scheme.toLowerCase();
    final protocol = '$scheme:';
    var username = '';
    var password = '';
    if (uri.userInfo.isNotEmpty) {
      final colon = uri.userInfo.indexOf(':');
      if (colon >= 0) {
        username = uri.userInfo.substring(0, colon);
        password = uri.userInfo.substring(colon + 1);
      } else {
        username = uri.userInfo;
      }
    }
    final hostname = uri.host.toLowerCase();
    var port = '';
    if (uri.hasPort) {
      final isDefault =
          (scheme == 'http' && uri.port == 80) ||
          (scheme == 'https' && uri.port == 443);
      if (!isDefault) port = uri.port.toString();
    }
    final pathname = uri.path.isEmpty ? '/' : uri.path;
    final search = uri.hasQuery ? '?${uri.query}' : '';
    final hash = uri.hasFragment ? '#${uri.fragment}' : '';
    return jsonEncode({
      'protocol': protocol,
      'username': username,
      'password': password,
      'hostname': hostname,
      'port': port,
      'pathname': pathname,
      'search': search,
      'hash': hash,
    });
  } catch (_) {
    return jsonEncode({'error': 'Invalid URL'});
  }
}

void _bindGlobalFunction(QuickJsRuntime2 runtime, String name, Function fn) {
  final setter = runtime.localContext['setToGlobalObject'];
  if (setter is JSInvokable) {
    setter.invoke([name, fn]);
  }
}

// =============================================================================
// Guard Bootstrap Worker Isolate
// =============================================================================

void _guardBootstrapIsolateEntry(List<Object?> startup) {
  final reply = startup[0] as SendPort;
  final rootPath = startup[1] as String;
  final transferable = startup[2] as TransferableTypedData;
  final adapter = startup[3] as String;
  final extension = startup[4] as String?;

  QuickJsRuntime2? runtime;
  try {
    final artifactBytes = transferable.materialize().asUint8List();
    runtime = QuickJsRuntime2(
      memoryLimit: 96 * 1024 * 1024,
      stackSize: 2 * 1024 * 1024,
      timeout: 3600,
    );

    _bindGlobalFunction(runtime, '__nativeParseUrl', _parseUrlForJs);
    _bindGlobalFunction(
      runtime,
      '__nativeHash',
      (String algo, Uint8List bytes) => CatPawCrypto.hashBytes(algo, bytes),
    );
    _bindGlobalFunction(
      runtime,
      '__nativeInflateRaw',
      (Uint8List bytes, int maxOut) =>
          CatPawCrypto.zlibInflate('inflateRaw', bytes, maxOutputLength: maxOut),
    );
    _bindGlobalFunction(
      runtime,
      '__nativeReadAsset',
      (String fileName) {
        if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*\.cjs$').hasMatch(fileName)) {
          throw const FormatException('guard_artifact_invalid');
        }
        final file = File('$rootPath/$fileName');
        if (!file.existsSync()) {
          throw const FormatException('guard_artifact_invalid');
        }
        return file.readAsStringSync();
      },
    );
    _bindGlobalFunction(runtime, '__nativeGetArtifact', () => artifactBytes);

    final init1 = runtime.evaluate(_quickJsCompatPrelude, name: 'compat.js');
    if (init1.isError) {
      reply.send({'error': 'guard_artifact_invalid'});
      return;
    }

    const bootstrapRunner = r'''
(function() {
  function toArrayBuffer(v) {
    if (v instanceof ArrayBuffer) return v;
    if (ArrayBuffer.isView(v)) {
      if (v.byteOffset === 0 && v.byteLength === v.buffer.byteLength) return v.buffer;
      return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength);
    }
    return Buffer.from(String(v)).buffer;
  }

  const nodeCrypto = {
    createHash(algo) {
      const chunks = [];
      return {
        update(data, encoding) {
          if (typeof data === 'string') chunks.push(Buffer.from(data, encoding || 'utf8'));
          else if (data instanceof Buffer) chunks.push(data);
          else if (ArrayBuffer.isView(data)) chunks.push(Buffer.from(data));
          else if (data instanceof ArrayBuffer) chunks.push(Buffer.from(data));
          else chunks.push(Buffer.from(String(data)));
          return this;
        },
        digest(encoding) {
          const all = chunks.length === 1 ? chunks[0] : Buffer.concat(chunks);
          const out = Buffer.from(__nativeHash(String(algo), toArrayBuffer(all)));
          return encoding ? out.toString(encoding) : out;
        },
      };
    },
  };

  const nodeZlib = {
    inflateRawSync(buf, opts) {
      const maxOut = (opts && typeof opts.maxOutputLength === 'number') ? opts.maxOutputLength : (8 * 1024 * 1024);
      const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
      return Buffer.from(__nativeInflateRaw(toArrayBuffer(b), maxOut));
    },
  };

  const moduleCache = Object.create(null);
  function customRequire(spec) {
    if (spec === 'node:crypto' || spec === 'crypto') return nodeCrypto;
    if (spec === 'node:zlib' || spec === 'zlib') return nodeZlib;
    if (spec === 'buffer' || spec === 'node:buffer') return { Buffer, kMaxLength: 0x7fffffff };
    let name = String(spec);
    if (name.startsWith('./')) name = name.slice(2);
    if (Object.prototype.hasOwnProperty.call(moduleCache, name)) return moduleCache[name].exports;
    const source = __nativeReadAsset(name);
    const mod = { exports: {} };
    moduleCache[name] = mod;
    const fn = new Function('require', 'module', 'exports', source);
    fn(customRequire, mod, mod.exports);
    return mod.exports;
  }

  globalThis.__runGuardBootstrap = function(adapter, extension) {
    try {
      const data = Buffer.from(__nativeGetArtifact());
      const { extractKnownPlugin, MAX } = customRequire('./drpy-guard-extractor.cjs');
      if (!data.length || data.length > MAX) throw new Error('invalid_artifact');
      const { FTY_ADAPTERS, extractFty } = customRequire('./drpy-fty-extractor.cjs');
      const { WEX_ADAPTERS, VOD_WEX_ADAPTERS, extractWex } = customRequire('./drpy-wex-extractor.cjs');
      const VOD_FTY = new Set(['jpys-v1', 'jpj-v1', 'nmyswv-v1', 'hmys-v1', 'app99-v1', 'appsx-v1', 'newcz-v1', 'libvio-v1', 'ygp-v1', 'jumitv-v1']);
      const LIVE_FTY = new Set(['kanqiu-v1', 'doubao-v1', 'livegz-v1', 'alllive-v1', 'tingshu275-v1', 'yueting-v1']);
      const VOD_WEX = new Set(VOD_WEX_ADAPTERS);
      const isFty = FTY_ADAPTERS.includes(adapter);
      const isWex = WEX_ADAPTERS.includes(adapter);
      if (!isFty && !isWex && !['dm84-v1', 'auete-v1', 'bttwoo-v1', 'appgz-v1', 't4-v1', 'apptt-v1', 'fy-v1'].includes(adapter)) {
        throw new Error('invalid_artifact');
      }
      const extVal = extension === null ? undefined : extension;
      const config = isFty ? extractFty(data, adapter, extVal) :
        isWex ? extractWex(data, adapter, extVal) :
        adapter === 't4-v1' ? customRequire('./drpy-t4-extractor.cjs').extractT4(data, extVal) :
        adapter === 'apptt-v1' ? customRequire('./drpy-apptt-extractor.cjs').extractAppTT(data, extVal) :
        adapter === 'fy-v1' ? customRequire('./drpy-fy-extractor.cjs').extractFy(data) :
        extractKnownPlugin(data, adapter);
      const factory = isFty
        ? (VOD_FTY.has(adapter) ? './drpy-fty-vod-adapter.cjs' : LIVE_FTY.has(adapter) ? './drpy-fty-live-adapter.cjs' : './drpy-fty-pan-adapter.cjs')
        : isWex
          ? (VOD_WEX.has(adapter) ? './drpy-wex-vod-adapter.cjs' : './drpy-wex-pan-adapter.cjs')
          : {
              'dm84-v1': './drpy-dm84-adapter.cjs',
              'auete-v1': './drpy-auete-adapter.cjs',
              'bttwoo-v1': './drpy-bttwoo-adapter.cjs',
              'appgz-v1': './drpy-appgz-adapter.cjs',
              't4-v1': './drpy-t4-adapter.cjs',
              'apptt-v1': './drpy-apptt-adapter.cjs',
              'fy-v1': './drpy-fy-adapter.cjs',
            }[adapter];
      const rule = customRequire(factory)(config);
      return JSON.stringify({ version: 1, rule, origin: config.origin });
    } catch (error) {
      const msg = error && error.message ? String(error.message) : '';
      const code = (msg === 'guard_artifact_unsupported' || msg === 'guard_artifact_integrity')
        ? msg : 'guard_artifact_invalid';
      return JSON.stringify({ error: code });
    }
  };
})();
''';
    final init2 = runtime.evaluate(bootstrapRunner, name: 'guard-bootstrap.js');
    if (init2.isError) {
      reply.send({'error': 'guard_artifact_invalid'});
      return;
    }

    final eval = runtime.evaluate(
      '__runGuardBootstrap(${jsonEncode(adapter)}, ${jsonEncode(extension)})',
      name: 'guard-run.js',
    );
    if (eval.isError) {
      reply.send({'error': 'guard_artifact_invalid'});
      return;
    }
    final decoded = jsonDecode(eval.stringResult);
    if (decoded is Map) {
      reply.send(decoded);
    } else {
      reply.send({'error': 'guard_artifact_invalid'});
    }
  } catch (e) {
    final msg = e is FormatException ? e.message : '';
    final code = const {
      'guard_artifact_unsupported',
      'guard_artifact_integrity',
    }.contains(msg)
        ? msg
        : 'guard_artifact_invalid';
    reply.send({'error': code});
  } finally {
    runtime?.dispose();
  }
}

// =============================================================================
// Persistent DRPY Worker Isolate
// =============================================================================

void _drpyWorkerIsolateEntry(List<Object?> startup) {
  final handshake = startup[0] as SendPort;
  final workerId = startup[1] as int;
  final rootPath = startup[2] as String;
  final stateDirPath = startup[3] as String;
  final manifest = Map<String, Object?>.from(startup[4] as Map);
  final publicProxyBase = startup[5] as String;
  final syncHttpPort = startup[6] as int;
  final syncHttpSecret = startup[7] as String;

  final commands = ReceivePort();
  _DrpyQuickJsSession? session;

  try {
    session = _DrpyQuickJsSession(
      workerId: workerId,
      rootPath: rootPath,
      stateDirPath: stateDirPath,
      manifest: manifest,
      publicProxyBase: publicProxyBase,
      syncHttpPort: syncHttpPort,
      syncHttpSecret: syncHttpSecret,
    );
    handshake.send([true, commands.sendPort]);
  } catch (e) {
    commands.close();
    handshake.send([false, e.toString()]);
    return;
  }

  commands.listen((dynamic message) {
    if (message is! List || message.isEmpty) return;
    final cmd = message[0];
    if (cmd == 'close') {
      final ack = message[1] as SendPort;
      session?.dispose();
      session = null;
      commands.close();
      ack.send(true);
      return;
    }
    if (cmd == 'call') {
      final reply = message[1] as SendPort;
      final method = message[2] as String;
      final args = (message[3] as List).cast<Object?>();
      final isProxy = message[4] as bool;
      try {
        final result = session!.execute(
          method: method,
          args: args,
          isProxy: isProxy,
        );
        if (result.error != null) {
          reply.send([false, result.error]);
        } else {
          reply.send([true, result.rawJson, result.usedProxy]);
        }
      } catch (_) {
        reply.send([false, 'drpy_source_failed']);
      }
    }
  });
}

class _DrpyQuickJsSession {
  static const int _maxResultBytes = 6 * 1024 * 1024;
  static const int _maxStorageBytes = 512 * 1024;
  static const int _maxStorageKeys = 2048;

  final int workerId;
  final String rootPath;
  final String stateDirPath;
  final Map<String, Object?> manifest;
  final String publicProxyBase;
  final int syncHttpPort;
  final String syncHttpSecret;

  late final QuickJsRuntime2 _runtime;
  final Map<String, Object?> _storage = {};
  late final File _stateFile;
  int _deadlineMs = 0;
  bool _initialized = false;
  bool _lastEncodingFailure = false;

  _DrpyQuickJsSession({
    required this.workerId,
    required this.rootPath,
    required this.stateDirPath,
    required this.manifest,
    required this.publicProxyBase,
    required this.syncHttpPort,
    required this.syncHttpSecret,
  }) {
    _stateFile = File('$stateDirPath/local.json');
    try {
      if (_stateFile.existsSync()) {
        final parsed = jsonDecode(_stateFile.readAsStringSync());
        if (parsed is Map) {
          parsed.forEach((k, v) => _storage[k.toString()] = v);
        }
      }
    } catch (_) {}

    _runtime = QuickJsRuntime2(
      memoryLimit: 128 * 1024 * 1024,
      stackSize: 2 * 1024 * 1024,
      timeout: 20000,
    );

    _bindNativeHooks();
    _loadCoreScripts();
  }

  void dispose() {
    _runtime.dispose();
  }

  void _bindNativeHooks() {
    _bindGlobalFunction(_runtime, '__nativeParseUrl', _parseUrlForJs);
    _bindGlobalFunction(_runtime, '__nativeReadEncodingCjs', () {
      return File('$rootPath/drpy-encoding.cjs').readAsStringSync();
    });

    _bindGlobalFunction(_runtime, '__request', (
      String url,
      String optionsText,
      String sourceEncoding,
    ) {
      return _bridgeCall(() => _handleRequest(url, optionsText, sourceEncoding));
    });

    _bindGlobalFunction(_runtime, '__local', (
      String action,
      String namespace,
      String key,
      String valueText,
    ) {
      return _bridgeCall(() => _handleLocal(action, namespace, key, valueText));
    });

    _bindGlobalFunction(_runtime, '__join', (String base, String part) {
      return _bridgeCall(() {
        final effectiveBase = base.isNotEmpty
            ? base
            : (manifest['origin'] as String);
        return Uri.parse(effectiveBase).resolve(part).toString();
      });
    });

    _bindGlobalFunction(_runtime, '__random', (int length) {
      return _bridgeCall(() => CatPawCrypto.randomBytes(length).toList());
    });

    _bindGlobalFunction(_runtime, '__rsaPkcs1', (
      String operation,
      String key,
      String input,
    ) {
      return _bridgeCall(() => CatPawCrypto.rsaPkcs1(operation, key, input));
    });

    _bindGlobalFunction(_runtime, '__rsaPubEnc', (String pem, String dataB64) {
      return _bridgeCall(() => CatPawCrypto.rsaPublicEncrypt(pem, dataB64));
    });

    _bindGlobalFunction(_runtime, '__zlib', (String mode, String inputB64) {
      return _bridgeCall(() => CatPawCrypto.zlibInflateBase64(mode, inputB64));
    });

    _bindGlobalFunction(_runtime, '__cipher', (
      String op,
      String algo,
      String keyB64,
      String ivB64,
      String dataB64,
      String tagB64,
    ) {
      return _bridgeCall(
        () => CatPawCrypto.nodeCipher(
          op: op,
          algo: algo,
          keyB64: keyB64,
          ivB64: ivB64,
          dataB64: dataB64,
          tagB64: tagB64,
        ),
      );
    });
  }

  String _bridgeCall(Object? Function() fn) {
    try {
      return jsonEncode({'value': fn()});
    } on FormatException catch (e) {
      final code = RegExp(r'^drpy_[a-z_]+$').hasMatch(e.message)
          ? e.message
          : 'drpy_host_error';
      return jsonEncode({'error': code});
    } catch (_) {
      return jsonEncode({'error': 'drpy_host_error'});
    }
  }

  Object? _handleLocal(
    String action,
    String namespace,
    String key,
    String valueText,
  ) {
    if (namespace.length > 256 || key.length > 512) {
      throw const FormatException('drpy_storage_key');
    }
    final storageKey = jsonEncode([namespace, key]);
    if (action == 'get') {
      return _storage.containsKey(storageKey) ? _storage[storageKey] : null;
    }
    final updated = Map<String, Object?>.of(_storage);
    if (action == 'delete') {
      updated.remove(storageKey);
    } else if (action == 'set') {
      updated[storageKey] = jsonDecode(valueText);
    } else {
      throw const FormatException('drpy_storage_action');
    }
    final encoded = jsonEncode(updated);
    if (utf8.encode(encoded).length > _maxStorageBytes ||
        updated.length > _maxStorageKeys) {
      throw const FormatException('drpy_storage_limit');
    }
    final tmp = File('${_stateFile.path}.tmp');
    tmp.writeAsStringSync(encoded, flush: true);
    tmp.renameSync(_stateFile.path);
    _storage
      ..clear()
      ..addAll(updated);
    return null;
  }

  Map<String, Object?> _handleRequest(
    String url,
    String optionsText,
    String sourceEncoding,
  ) {
    final options = jsonDecode(optionsText);
    final optMap = options is Map
        ? Map<String, Object?>.from(options)
        : <String, Object?>{};
    final origin = Uri.parse(manifest['origin'] as String);
    final resolved = origin.resolve(url);
    if (resolved.scheme == 'pkg') {
      final method = (optMap['method']?.toString() ?? 'GET').toUpperCase();
      final modules = manifest['modules'] as Map;
      final href = resolved.toString();
      if (method != 'GET' || !modules.containsKey(href)) {
        _runtime.evaluate(
          'globalThis.__drpyUnsupported = "drpy_local_module_missing";',
        );
        throw const FormatException('drpy_local_module_missing');
      }
      final text = modules[href] as String;
      _lastEncodingFailure = false;
      return {
        'code': 200,
        'content': optMap['buffer'] == 2
            ? base64Encode(utf8.encode(text))
            : text,
        'headers': {
          'content-type': resolved.path.endsWith('.json')
              ? 'application/json'
              : 'text/javascript',
        },
        'url': href,
      };
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final defaultTimeout = (manifest['requestTimeoutMs'] as int?) ?? 10000;
    final optTimeout = (optMap['timeout'] as num?)?.toInt() ?? defaultTimeout;
    final remaining = _deadlineMs - nowMs;
    final duration = min(min(max(optTimeout, 100), 15000), remaining);
    if (duration <= 0) {
      throw const FormatException('drpy_http_timeout');
    }

    final reqPayload = utf8.encode(
      jsonEncode({
        'workerId': workerId,
        'url': url,
        'options': optMap,
        'sourceEncoding': sourceEncoding,
        'deadline': min(_deadlineMs, nowMs + duration),
      }),
    );

    RawSynchronousSocket? sock;
    try {
      sock = RawSynchronousSocket.connectSync(
        InternetAddress.loopbackIPv4,
        syncHttpPort,
      );
      final header = Uint8List(36);
      header.setRange(0, 32, ascii.encode(syncHttpSecret));
      ByteData.sublistView(header, 32, 36).setUint32(
        0,
        reqPayload.length,
        Endian.big,
      );
      sock.writeFromSync(header);
      sock.writeFromSync(reqPayload);

      final lenBytes = _readExactSync(sock, 4);
      if (lenBytes == null) {
        throw const FormatException('drpy_http_timeout');
      }
      final respLen = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
      if (respLen <= 0 || respLen > _maxResultBytes + 65536) {
        throw const FormatException('drpy_http_response');
      }
      final respBytes = _readExactSync(sock, respLen);
      if (respBytes == null) {
        throw const FormatException('drpy_http_response_failed');
      }
      final parsed = jsonDecode(utf8.decode(respBytes));
      if (parsed is! Map) {
        throw const FormatException('drpy_http_response');
      }
      final err = parsed['error'];
      if (err is String && err.isNotEmpty) {
        if (err == 'drpy_http_encoding') _lastEncodingFailure = true;
        throw FormatException(err);
      }
      _lastEncodingFailure = false;
      return parsed.map((k, v) => MapEntry(k.toString(), v as Object?));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('drpy_http_connection_failed');
    } finally {
      try {
        sock?.closeSync();
      } catch (_) {}
    }
  }

  static Uint8List? _readExactSync(RawSynchronousSocket sock, int count) {
    final out = Uint8List(count);
    var offset = 0;
    while (offset < count) {
      final read = sock.readIntoSync(out, offset, count);
      if (read <= 0) return null;
      offset += read;
    }
    return out;
  }

  void _evalChecked(String code, String name) {
    final res = _runtime.evaluate(code, name: name);
    if (res.isError) {
      throw FormatException(res.stringResult);
    }
  }

  void _loadCoreScripts() {
    _evalChecked(_quickJsCompatPrelude, 'compat.js');

    final bootstrapJs = '''
function bridgeValue(text) {
  const value = JSON.parse(text);
  if (value.error) throw new Error(value.error);
  return value.value;
}
let __iconv = null;
function __decodeLegacyCharset(b64, charset) {
  if (!__iconv) {
    const src = __nativeReadEncodingCjs();
    const mod = { exports: {} };
    const StringDecoder = function(enc) { this.enc = enc || 'utf8'; };
    StringDecoder.prototype.write = function(b) { return Buffer.from(b).toString(this.enc); };
    StringDecoder.prototype.end = function() { return ''; };
    const reqFn = function(name) {
      if (name === 'buffer' || name === 'node:buffer') return { Buffer, kMaxLength: 0x7fffffff };
      if (name === 'string_decoder' || name === 'node:string_decoder') return { StringDecoder };
      throw new Error('unsupported');
    };
    new Function('require', 'module', 'exports', src)(reqFn, mod, mod.exports);
    __iconv = mod.exports;
  }
  const label = String(charset || '').trim().toLowerCase().replace(/[-_]/g, '');
  const buf = Buffer.from(b64, 'base64');
  if (['gbk','gb2312','gb231280','csgb2312','csiso58gb231280','chinese','isoir58','xgbk','cp936','ms936','windows936'].includes(label)) {
    return __iconv.decode(buf, 'gbk');
  }
  if (label === 'gb18030') return __iconv.decode(buf, 'gb18030');
  if (['big5','big5hkscs','cnbig5','csbig5','xxbig5','cp950','windows950'].includes(label)) {
    return __iconv.decode(buf, 'big5');
  }
  throw new Error('drpy_http_encoding');
}
globalThis.crypto = {
  getRandomValues(array) {
    const bytes = bridgeValue(__random(array.byteLength));
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    return array;
  },
};
globalThis.rsaPkcs1 = (operation, key, input) => {
  try { return bridgeValue(__rsaPkcs1(String(operation || ''), String(key || ''), String(input || ''))); }
  catch (e) { unsupportedFeature('drpy_crypto_invalid'); }
};
globalThis.rsaPublicEncrypt = (pem, dataB64) => {
  try { return bridgeValue(__rsaPubEnc(String(pem || ''), String(dataB64 || ''))); }
  catch (e) { unsupportedFeature('drpy_crypto_invalid'); }
};
globalThis.zlibInflate = (mode, inputB64) => {
  try { return bridgeValue(__zlib(String(mode || ''), String(inputB64 || ''))); }
  catch (e) { unsupportedFeature('drpy_crypto_invalid'); }
};
globalThis.nodeCipher = (op, algo, keyB64, ivB64, dataB64, tagB64) => {
  try { return bridgeValue(__cipher(String(op || ''), String(algo || ''), String(keyB64 || ''), String(ivB64 || ''), String(dataB64 || ''), String(tagB64 || ''))); }
  catch (e) { unsupportedFeature('drpy_crypto_invalid'); }
};
globalThis.req = (url, options = {}) => {
  const encoding = typeof rule === 'object' && rule ? (rule.encoding || rule['编码']) : '';
  const result = bridgeValue(__request(String(url), JSON.stringify(options || {}), typeof encoding === 'string' ? encoding : ''));
  if (result && typeof result.contentB64 === 'string') {
    result.content = __decodeLegacyCharset(result.contentB64, result.charset || '');
    delete result.contentB64;
    delete result.charset;
  }
  return result;
};
globalThis.__drpyOrigin = ${jsonEncode(manifest['origin'])};
globalThis.__drpyProxy = ${jsonEncode(publicProxyBase)};
globalThis.joinUrl = (base, part) => bridgeValue(__join(String(base || ''), String(part || '')));
globalThis.local = {
  get: (ns, key) => bridgeValue(__local('get', String(ns), String(key), '')),
  set: (ns, key, value) => bridgeValue(__local('set', String(ns), String(key), JSON.stringify(value))),
  delete: (ns, key) => bridgeValue(__local('delete', String(ns), String(key), '')),
};
function unsupportedFeature(code) { globalThis.__drpyUnsupported = code; throw new Error(code); }
globalThis.getProxy = () => globalThis.__drpyProxy;
''';
    _evalChecked(bootstrapJs, 'drpy-host-bootstrap.js');

    final deps = File('$rootPath/drpy-dependencies.js').readAsStringSync();
    _evalChecked(deps, 'drpy-dependencies.js');

    const selectorsJs = r'''
function selectHtml(html, parts) {
  const $ = DRPYDeps.cheerio.load(String(html));
  let selected = $.root();
  for (const step of parts) {
    if (!step) continue;
    const cuts = step.split('--'), selector = cuts.shift().trim();
    if (selector && selector !== '*') selected = selected.find(selector);
    if (cuts.length) {
      selected = selected.clone();
      for (const cut of cuts) selected.find(cut).remove();
    }
  }
  return { $, selected };
}
globalThis.pdfa = (html, expression) => {
  const { $, selected } = selectHtml(html, String(expression).split('&&'));
  return selected.toArray().map(node => $.html(node));
};
globalThis.pdfl = globalThis.pdfa;
globalThis.pdfh = (html, expression) => {
  const parts = String(expression).split('&&');
  const field = parts.pop();
  const { selected } = selectHtml(html, parts);
  const first = selected.first();
  if (field === 'Text') return first.text().trim();
  if (field === 'Html') return first.html() || '';
  return first.attr(field) || '';
};
globalThis.pd = (html, expression, base) => {
  const value = pdfh(html, expression);
  return value ? joinUrl(base, value) : '';
};
''';
    _evalChecked(selectorsJs, 'drpy-host-selectors.js');

    final core = File('$rootPath/drpy-core.js').readAsStringSync();
    _evalChecked(core, 'drpy-core.js');
  }

  _DrpyCallResult execute({
    required String method,
    required List<Object?> args,
    required bool isProxy,
  }) {
    _deadlineMs = DateTime.now().millisecondsSinceEpoch + 20000;
    _lastEncodingFailure = false;
    _runtime.setOperationTimeout(const Duration(seconds: 20));
    try {
      _runtime.evaluate('globalThis.__drpyUnsupported = null;');
      if (!_initialized) {
        final ruleCode = manifest['rule'] as String;
        final initCode =
            '__drpy.init((function(){\n$ruleCode\n;'
            'if(typeof rule!=="object"||rule===null)throw new Error("drpy_rule_missing");'
            'return rule;})());';
        final initRes = _runtime.evaluate(initCode, name: 'drpy-source-init');
        if (initRes.isError) {
          return _DrpyCallResult(error: _extractErrorCode(initRes.stringResult));
        }
        final unsupported = _readUnsupportedCode();
        if (unsupported != null) return _DrpyCallResult(error: unsupported);
        _initialized = true;
      }

      final argsJson = jsonEncode(args);
      final expr =
          '(()=>{const args=JSON.parse(${jsonEncode(argsJson)});'
          'const result=__drpy[${jsonEncode(method)}](...args);'
          'if(result&&typeof result.then==="function")throw new Error("drpy_async_result");'
          'return typeof result==="string"?result:JSON.stringify(result);})()';
      final remainingMs = max(
        1,
        _deadlineMs - DateTime.now().millisecondsSinceEpoch,
      );
      _runtime.setOperationTimeout(Duration(milliseconds: remainingMs));
      final evalRes = _runtime.evaluate(expr, name: 'drpy-source-$method');
      if (evalRes.isError) {
        return _DrpyCallResult(error: _extractErrorCode(evalRes.stringResult));
      }
      final unsupported = _readUnsupportedCode();
      if (unsupported != null) return _DrpyCallResult(error: unsupported);

      final raw = evalRes.rawResult is String
          ? evalRes.rawResult as String
          : evalRes.stringResult;
      if (utf8.encode(raw).length > _maxResultBytes) {
        return const _DrpyCallResult(error: 'drpy_result');
      }
      final parsed = jsonDecode(raw);
      if (isProxy) {
        return _DrpyCallResult(rawJson: jsonEncode(parsed), usedProxy: true);
      }
      if (parsed is! Map) {
        return const _DrpyCallResult(error: 'drpy_result');
      }
      final resultMap = Map<String, Object?>.from(parsed);
      if (method == 'category' &&
          resultMap['list'] is List &&
          (resultMap['list'] as List).length == 1) {
        final row = (resultMap['list'] as List).first;
        if (row is Map &&
            row['vod_id'] == 'no_data' &&
            row['vod_name'] == '无数据,防无限请求' &&
            row['vod_remarks'] == '不要点,会崩的' &&
            row['vod_pic'] == '' &&
            resultMap['total'] == 1 &&
            resultMap['pagecount'] == 1 &&
            resultMap['limit'] == 1) {
          if (_lastEncodingFailure) {
            return const _DrpyCallResult(error: 'drpy_http_encoding');
          }
          resultMap['list'] = <Object?>[];
          resultMap['total'] = 0;
        }
      }
      final outJson = jsonEncode(resultMap);
      final usedProxy = method == 'play' && outJson.contains(publicProxyBase);
      return _DrpyCallResult(rawJson: outJson, usedProxy: usedProxy);
    } catch (e) {
      return _DrpyCallResult(error: _extractErrorCode(e.toString()));
    } finally {
      _deadlineMs = 0;
    }
  }

  String? _readUnsupportedCode() {
    final res = _runtime.evaluate('globalThis.__drpyUnsupported || ""');
    if (!res.isError && res.stringResult.isNotEmpty) {
      final code = res.stringResult;
      if (RegExp(r'^drpy_[a-z_]+$').hasMatch(code)) return code;
    }
    return null;
  }

  String _extractErrorCode(String rawError) {
    final unsupported = _readUnsupportedCode();
    if (unsupported != null) return unsupported;
    final match = RegExp(r'\b(drpy_[a-z_]+)\b').firstMatch(rawError);
    if (match != null) return match.group(1)!;
    if (rawError.toLowerCase().contains('interrupted') ||
        rawError.toLowerCase().contains('timeout')) {
      return 'drpy_execution_timeout';
    }
    return 'drpy_source_failed';
  }
}

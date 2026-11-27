import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'catpaw_host.dart';
import 'csp_bridge.dart';
import 'drpy_source.dart';
import 'models.dart';

/// Ports only explicitly reviewed plugin versions. Plugin bytes are treated as
/// data; the local bootstrap never executes the imported Android implementation.
class GuardSource {
  static const maxArtifactBytes = 16 * 1024 * 1024;
  final CatPawHost host;
  final DrpySource drpy;
  final Future<Uint8List> Function(String, Map<String, String>) read;
  final _cache = <String, ({String rule, String origin, DateTime expires})>{};
  final _inFlightReads = <String, Future<Uint8List>>{};
  final _inFlightBootstraps =
      <
        String,
        ({
          Future<({String rule, String origin, DateTime expires})> future,
          Completer<void> sharedCancel,
          int Function(int delta) adjustWaiters,
        })
      >{};

  GuardSource({required this.host, required this.drpy, required this.read});

  static bool supports(CmsSite site) =>
      CspBridge.guardAdapterFor(site) != null &&
      site.pluginReference.trim().isNotEmpty;

  Future<String> invoke(
    CmsSite site,
    String method,
    List<Object?> args, {
    Completer<void>? cancellation,
  }) async {
    void checkCancelled() {
      if (cancellation?.isCompleted == true)
        throw const FormatException('搜索已取消');
    }

    checkCancelled();
    final adapter = CspBridge.guardAdapterFor(site);
    if (adapter == null) throw const FormatException('此插件没有已审阅的移植适配器');
    const requiredExtAdapters = {
      't4-v1',
      'apptt-v1',
      'app99-v1',
      'appsx-v1',
    };
    const optionalExtAdapters = {
      'jpys-v1',
      'jpj-v1',
      'nmyswv-v1',
      'hmys-v1',
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
      'jumitv-v1',
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
    final needsExtension = requiredExtAdapters.contains(adapter);
    final optionalExtension = optionalExtAdapters.contains(adapter);
    if (needsExtension &&
        (site.ext.trim().isEmpty || utf8.encode(site.ext).length > 16 * 1024)) {
      throw const FormatException('此插件需要订阅中的完整扩展配置');
    }
    if (optionalExtension && utf8.encode(site.ext).length > 16 * 1024) {
      throw const FormatException('此插件扩展配置超过上限');
    }
    final forwardedExtension = needsExtension
        ? site.ext
        : (optionalExtension && site.ext.trim().isNotEmpty ? site.ext : null);
    if (adapter == 'auete-v1' || adapter == 'bttwoo-v1') {
      Object? extension;
      try {
        extension = jsonDecode(site.ext);
      } catch (_) {
        /* Non-JSON ext has no mapped override. */
      }
      if (extension is Map &&
          extension['siteUrl'] != null &&
          extension['siteUrl'].toString().trim().isNotEmpty) {
        final name = adapter == 'auete-v1' ? 'Auete' : 'Bttwoo';
        throw FormatException('$name 自定义 siteUrl 变体暂未适配');
      }
    }
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              adapter,
              site.subscriptionId,
              site.sourceKey,
              site.isEffectivelyPrivate,
              site.pluginReference,
              site.headers,
              if (forwardedExtension != null) forwardedExtension,
            ]),
          ),
        )
        .toString();
    var item = _cache[key];
    final declaration = site.pluginReference;
    final marker = RegExp(
      ';md5;',
      caseSensitive: false,
    ).firstMatch(declaration);
    final address =
        (marker == null ? declaration : declaration.substring(0, marker.start))
            .trim();
    final expected = marker == null ? null : declaration.substring(marker.end);
    if (expected != null && !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(expected)) {
      throw const FormatException('插件摘要格式无效，请检查订阅中的完整地址');
    }
    final artifact = Uri.tryParse(address);
    if (artifact == null ||
        !['http', 'https'].contains(artifact.scheme) ||
        artifact.host.isEmpty) {
      throw const FormatException('此插件需要订阅提供完整的 HTTP(S) 插件地址');
    }
    if (item == null || DateTime.now().isAfter(item.expires)) {
      checkCancelled();
      var entry = _inFlightBootstraps[key];
      if (entry == null) {
        final sharedCancel = Completer<void>();
        var waiters = 0;
        int adjust(int delta) => waiters += delta;
        late final ({
          Future<({String rule, String origin, DateTime expires})> future,
          Completer<void> sharedCancel,
          int Function(int delta) adjustWaiters,
        }) created;
        final future = () async {
          final readKey = jsonEncode([address, site.headers]);
          var pendingRead = _inFlightReads[readKey];
          if (pendingRead == null) {
            pendingRead = Future<Uint8List>.sync(
              () => read(address, site.headers),
            );
            _inFlightReads[readKey] = pendingRead;
            pendingRead.whenComplete(() {
              if (identical(_inFlightReads[readKey], pendingRead)) {
                _inFlightReads.remove(readKey);
              }
            }).ignore();
          }
          final bytes = await pendingRead;
          if (sharedCancel.isCompleted) {
            throw const FormatException('搜索已取消');
          }
          if (bytes.isEmpty || bytes.length > maxArtifactBytes) {
            throw const FormatException('插件包为空或超过 16 MB');
          }
          if (expected != null &&
              md5.convert(bytes).toString() != expected.toLowerCase()) {
            throw const FormatException('插件摘要校验失败，请刷新原订阅后重试');
          }
          final generated = await host.bootstrapGuard(
            bytes,
            adapter: adapter,
            extension: forwardedExtension,
            cancellation: sharedCancel,
          );
          if (sharedCancel.isCompleted) {
            throw const FormatException('搜索已取消');
          }
          final resolved = (
            rule: generated['rule'] as String,
            origin: generated['origin'] as String,
            expires: DateTime.now().add(const Duration(minutes: 30)),
          );
          if (_cache.length >= 128) _cache.remove(_cache.keys.first);
          _cache[key] = resolved;
          return resolved;
        }();
        created = (
          future: future,
          sharedCancel: sharedCancel,
          adjustWaiters: adjust,
        );
        _inFlightBootstraps[key] = created;
        future.whenComplete(() {
          if (identical(_inFlightBootstraps[key], created)) {
            _inFlightBootstraps.remove(key);
          }
        }).ignore();
        entry = created;
      }
      entry.adjustWaiters(1);
      var released = false;
      void releaseWaiter() {
        if (released) return;
        released = true;
        if (entry!.adjustWaiters(-1) <= 0 && !entry.sharedCancel.isCompleted) {
          entry.sharedCancel.complete();
        }
      }
      final cancelSub = cancellation?.future.asStream().listen((_) {
        releaseWaiter();
      });
      try {
        item = cancellation == null
            ? await entry.future
            : await Future.any([
                entry.future,
                cancellation.future.then<
                  ({String rule, String origin, DateTime expires})
                >((_) => throw const FormatException('搜索已取消')),
              ]);
      } finally {
        releaseWaiter();
        await cancelSub?.cancel();
      }
      checkCancelled();
    }
    final activeItem = item!;
    final target = Uri.parse(activeItem.origin);
    final sameOrigin =
        artifact.scheme == target.scheme &&
        artifact.host == target.host &&
        artifact.port == target.port;
    final runtimeHeaders = Map<String, String>.fromEntries(
      site.headers.entries.where(
        (entry) =>
            sameOrigin ||
            !const [
              'authorization',
              'cookie',
              'cookie2',
              'proxy-authorization',
            ].contains(entry.key.toLowerCase()),
      ),
    );
    // Import/download credentials belong to the plugin origin, not to endpoints
    // extracted from its content. Explicit rule playback headers remain intact.
    return drpy.invoke(
      site.copyWith(
        // Namespace only the internal DRPY identity. Preserve the original
        // subscription/history identity and the existing DM84 state location.
        subscriptionId: adapter == 'dm84-v1'
            ? site.subscriptionId
            : jsonEncode([
                'guard-adapter',
                adapter,
                site.subscriptionId,
                if (site.subscriptionId.isEmpty) ...[
                  site.pluginReference,
                  activeItem.origin,
                ],
              ]),
        headers: runtimeHeaders,
        ext: jsonEncode({
          'ruleHash': sha256.convert(utf8.encode(activeItem.rule)).toString(),
          'originalExt': site.ext,
        }),
      ),
      method,
      args,
      rule: activeItem.rule,
      origin: activeItem.origin,
      cancellation: cancellation,
    );
  }
}

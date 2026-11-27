import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// System DNS first, bounded DoH only on lookup failure. Connections keep the
/// original request URI, Host and TLS SNI; certificate validation is unchanged.
/// The injectable lookup/client make DNS failure tests entirely offline.
class CmsDohResolver {
  static final CmsDohResolver shared = CmsDohResolver();

  final Future<List<InternetAddress>> Function(String) systemLookup;
  final http.Client? client;
  final DateTime Function() now;
  final Duration lookupTimeout;
  final Duration queryTimeout;
  final _cache =
      <String, ({List<InternetAddress> addresses, DateTime expires})>{};

  static const _providers = [
    ('https://dns.alidns.com/resolve', '223.5.5.5'),
    ('https://cloudflare-dns.com/dns-query', '1.1.1.1'),
    ('https://dns.google/resolve', '8.8.8.8'),
  ];

  CmsDohResolver({
    Future<List<InternetAddress>> Function(String)? systemLookup,
    this.client,
    DateTime Function()? now,
    this.lookupTimeout = const Duration(seconds: 2),
    this.queryTimeout = const Duration(seconds: 3),
  })  : systemLookup = systemLookup ?? InternetAddress.lookup,
        now = now ?? DateTime.now;

  Future<List<InternetAddress>> resolve(
    String host, {
    Future<void>? cancellation,
  }) async {
    var cancelled = false;
    final interrupted = Completer<List<InternetAddress>>();
    final listener = cancellation?.asStream().listen((_) {
      cancelled = true;
      if (!interrupted.isCompleted) {
        interrupted.completeError(const SocketException('DNS lookup cancelled'));
      }
    });
    void check() {
      if (cancelled) throw const SocketException('DNS lookup cancelled');
    }

    Future<List<InternetAddress>> work() async {
      check();
      final cleanHost = host.startsWith('[') && host.endsWith(']')
          ? host.substring(1, host.length - 1)
          : host;
      final literal = InternetAddress.tryParse(cleanHost);
      if (literal != null) return [literal];
      try {
        final addresses = await systemLookup(host).timeout(lookupTimeout);
        check();
        if (addresses.isNotEmpty) return addresses;
      } on SocketException {
        check();
      } on TimeoutException {
        check();
      }
      // Private/LAN names must not leak to public resolvers.
      final name = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
      if (!name.contains('.') ||
          name.endsWith('.local') ||
          name.endsWith('.localhost') ||
          name.endsWith('.lan') ||
          name.endsWith('.invalid') ||
          name.endsWith('.test') ||
          name.endsWith('.example')) {
        throw const SocketException('Local DNS lookup failed');
      }
      final cached = _cache[name];
      if (cached != null && now().isBefore(cached.expires)) {
        return cached.addresses;
      }
      _cache.remove(name);
      for (final (endpoint, bootstrap) in _providers) {
        check();
        final results = await Future.wait([
          for (final type in const ['A', 'AAAA'])
            _query(
              Uri.parse(endpoint)
                  .replace(queryParameters: {'name': name, 'type': type}),
              bootstrap,
              cancellation: cancellation,
            ).catchError((Object _) => ''),
        ]);
        check();
        final addresses = <InternetAddress>[];
        final seen = <String>{};
        var ttl = 300;
        for (final raw in results) {
          try {
            final data = jsonDecode(raw);
            if (data is! Map ||
                data['Status'] != 0 ||
                data['TC'] == true ||
                data['Answer'] is! List) {
              continue;
            }
            final records = (data['Answer'] as List).whereType<Map>().toList();
            final owners = <String>{name};
            String owner(Object? value) =>
                '$value'.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
            for (var i = 0; i < 8; i++) {
              for (final r in records.where(
                  (r) => r['type'] == 5 && owners.contains(owner(r['name'])))) {
                owners.add(owner(r['data']));
              }
            }
            for (final r in records) {
              if (!owners.contains(owner(r['name'])) ||
                  !const [1, 28].contains(r['type'])) {
                continue;
              }
              final address = InternetAddress.tryParse('${r['data']}');
              if (address == null ||
                  address.address == '0.0.0.0' ||
                  address.address == '::' ||
                  (r['type'] == 1) !=
                      (address.type == InternetAddressType.IPv4)) {
                continue;
              }
              if (seen.add(address.address)) addresses.add(address);
              final seconds = int.tryParse('${r['TTL']}') ?? 0;
              if (seconds < ttl) ttl = seconds.clamp(0, 300);
            }
          } on FormatException {
            // Try the other family/provider.
          }
        }
        if (addresses.isNotEmpty) {
          if (_cache.length >= 128) _cache.remove(_cache.keys.first);
          if (ttl > 0) {
            _cache[name] = (
              addresses: addresses,
              expires: now().add(Duration(seconds: ttl)),
            );
          }
          return addresses;
        }
      }
      throw const SocketException('System DNS and DoH lookup failed');
    }

    try {
      return await Future.any(
          [Future<List<InternetAddress>>.sync(work), interrupted.future]);
    } finally {
      unawaited(listener?.cancel() ?? Future<void>.value());
    }
  }

  Future<ConnectionTask<Socket>> _connectBootstrap(
    Uri target,
    String? proxyHost,
    int? proxyPort,
    String bootstrap,
  ) async {
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? target.port);
    }
    final port =
        target.hasPort ? target.port : (target.isScheme('https') ? 443 : 80);
    final task = await Socket.startConnect(InternetAddress(bootstrap), port);
    if (!target.isScheme('https')) return task;
    Socket? raw;
    var cancelled = false;
    Future<Socket> upgrade() async {
      raw = await task.socket.timeout(queryTimeout, onTimeout: () {
        task.cancel();
        throw const SocketException('DoH TCP connect timed out');
      });
      if (cancelled) {
        raw!.destroy();
        throw const SocketException('DoH connection cancelled');
      }
      try {
        return await SecureSocket.secure(raw!, host: target.host)
            .timeout(queryTimeout, onTimeout: () {
          raw?.destroy();
          throw const SocketException('DoH TLS handshake timed out');
        });
      } catch (_) {
        raw?.destroy();
        rethrow;
      }
    }

    return ConnectionTask.fromSocket(upgrade(), () {
      cancelled = true;
      task.cancel();
      raw?.destroy();
    });
  }

  Future<String> _query(
    Uri uri,
    String bootstrap, {
    Future<void>? cancellation,
  }) async {
    final transport = client ??
        IOClient(HttpClient()
          ..connectionTimeout = queryTimeout
          ..connectionFactory = (target, proxyHost, proxyPort) =>
              _connectBootstrap(target, proxyHost, proxyPort, bootstrap));
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      if (client == null) transport.close();
    }

    final listener = cancellation?.asStream().listen((_) => cancel());
    final deadline = Timer(queryTimeout, cancel);
    try {
      final response = await transport
          .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Accept'] = 'application/dns-json')
          .timeout(queryTimeout);
      if (response.statusCode != 200 || (response.contentLength ?? 0) > 65536) {
        await response.stream.listen(null).cancel();
        throw const FormatException('Invalid DoH response');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.stream.timeout(queryTimeout)) {
        if (bytes.length + part.length > 65536) {
          throw const FormatException('DoH response too large');
        }
        bytes.add(part);
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      deadline.cancel();
      unawaited(listener?.cancel() ?? Future<void>.value());
      cancel();
    }
  }

  Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    // Respect configured proxies; they own target-host resolution and CONNECT tunneling.
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? uri.port);
    }
    final abort = Completer<void>();
    ConnectionTask<Socket>? active;
    Socket? rawSocket;
    Socket? connected;
    void check() {
      if (abort.isCompleted) {
        throw const SocketException('Connection cancelled');
      }
    }

    final port = uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80);
    Future<Socket> open() async {
      final addresses = await resolve(uri.host, cancellation: abort.future);
      for (final address in addresses) {
        check();
        try {
          active = await Socket.startConnect(address, port);
          if (abort.isCompleted) active!.cancel();
          rawSocket =
              await active!.socket.timeout(const Duration(seconds: 4), onTimeout: () {
            active?.cancel();
            throw const SocketException('Connection timed out');
          });
          check();
          if (uri.isScheme('https')) {
            try {
              connected = await SecureSocket.secure(rawSocket!, host: uri.host)
                  .timeout(const Duration(seconds: 6), onTimeout: () {
                rawSocket?.destroy();
                throw const SocketException('TLS handshake timed out');
              });
            } catch (_) {
              rawSocket?.destroy();
              rawSocket = null;
              rethrow;
            }
          } else {
            connected = rawSocket;
          }
          check();
          return connected!;
        } on SocketException {
          rawSocket?.destroy();
          rawSocket = null;
          check();
        }
      }
      throw const SocketException('No reachable address');
    }

    return ConnectionTask.fromSocket(open(), () {
      if (!abort.isCompleted) abort.complete();
      active?.cancel();
      rawSocket?.destroy();
      connected?.destroy();
    });
  }
}

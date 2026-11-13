import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:marco_movie/core/lan_sync_server.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Adversarial F8: LAN Sync Server Graceful Socket Closure & Leak Prevention', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      storage = await StorageService.init();
    });

    test('Adversarial 1: Server closes socket cleanly on expiration and port is immediately re-bindable', () async {
      // 1. Start LanSyncServer with very short TTL (150ms)
      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(milliseconds: 150),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      final assignedPort = server.port;
      expect(assignedPort, greaterThan(0));
      expect(server.isClosed, isFalse);

      // Verify server is listening and accepts requests
      final liveResp = await http.get(Uri.parse(server.addressForHost('127.0.0.1')));
      expect(liveResp.statusCode, 200);

      // Wait for expiration timer to trigger (250ms > 150ms)
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(server.isClosed, isTrue);
      expect(server.isExpired, isTrue);

      // 2. Critical verification: accessing server.port after closure MUST NOT throw
      // (Worker cached `port = server.port` during initialization)
      expect(() => server.port, returnsNormally);
      expect(server.port, equals(assignedPort));

      // 3. Port release & re-binding test:
      // If the socket was leaked or not closed, binding to assignedPort will fail with
      // SocketException: Failed to create server socket (OS Error: Only one usage of each socket address)
      HttpServer? reboundServer;
      try {
        reboundServer = await HttpServer.bind(InternetAddress.loopbackIPv4, assignedPort);
        expect(reboundServer.port, equals(assignedPort), reason: 'Assigned port was cleanly freed and re-bound');
      } finally {
        await reboundServer?.close(force: true);
      }
    });

    test('Adversarial 2: Expired request receives HTTP 410 Gone and initiates microtask socket closure', () async {
      // Start server with negative TTL so it is expired from the start
      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(milliseconds: -50),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(server.close);

      expect(server.isExpired, isTrue);

      // Send request to expired server
      final resp = await http.get(Uri.parse(server.addressForHost('127.0.0.1')));
      expect(resp.statusCode, 410);
      expect(resp.body, contains('局域网同步会话已过期'));

      // Microtask closure will execute on the next event turn
      await pumpEventQueue();
      expect(server.isClosed, isTrue);

      // Subsequent connection must fail
      expect(
        () => http.get(Uri.parse(server.addressForHost('127.0.0.1'))),
        throwsA(anyOf(isA<SocketException>(), isA<http.ClientException>())),
      );
    });

    test('Adversarial 3: Concurrent requests under expiration boundary do not leak sockets or crash', () async {
      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(milliseconds: 100),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(server.close);

      // Fire 10 concurrent requests right around the expiration moment
      final client = http.Client();
      try {
        final futures = List.generate(10, (idx) async {
          await Future<void>.delayed(Duration(milliseconds: 50 + idx * 15));
          try {
            return await client.get(Uri.parse(server.addressForHost('127.0.0.1')));
          } catch (e) {
            // SocketException or ClientException is expected once socket is closed
            return e;
          }
        });

        final results = await Future.wait(futures);
        for (final res in results) {
          if (res is http.Response) {
            // Must be either 200 (if handled before expiry) or 410 (if handled after expiry)
            expect(res.statusCode, anyOf(200, 410));
          } else {
            // Must be a cleanly closed socket error
            expect(res, anyOf(isA<SocketException>(), isA<http.ClientException>()));
          }
        }
      } finally {
        client.close();
      }

      // Allow all timers to flush
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.isClosed, isTrue);
    });

    test('Adversarial 4: Peer address filtering blocks WAN IPv4/IPv6 and allows LAN/loopback/CGNAT', () {
      // WAN addresses MUST be rejected
      final blockedWan = [
        '8.8.8.8',
        '8.8.4.4',
        '1.1.1.1',
        '203.0.113.1',
        '198.51.100.1',
        '93.184.216.34',
        '100.128.0.1', // Just outside CGNAT 100.64.0.0/10
        '172.32.0.1',  // Just outside RFC 1918 172.16.0.0/12
        '192.169.0.1', // Just outside RFC 1918 192.168.0.0/16
        '2001:db8::1',
        '2606:4700::1',
      ];
      for (final ip in blockedWan) {
        expect(
          LanSyncServer.isAllowedPeerAddress(InternetAddress(ip)),
          isFalse,
          reason: 'WAN IP $ip must be blocked',
        );
      }

      // LAN addresses MUST be allowed
      final allowedLan = [
        '127.0.0.1',
        '127.255.255.255',
        '::1',
        '192.168.1.1',
        '192.168.254.254',
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '100.64.0.1',  // CGNAT start
        '100.127.255.254', // CGNAT end
        '169.254.1.1', // Link-local
        'fc00::1',     // IPv6 ULA
        'fd12:3456:789a::1',
      ];
      for (final ip in allowedLan) {
        expect(
          LanSyncServer.isAllowedPeerAddress(InternetAddress(ip)),
          isTrue,
          reason: 'LAN IP $ip must be allowed',
        );
      }
    });

    test('Adversarial 5: Calling close() multiple times is idempotent', () async {
      final server = await LanSyncServer.start(
        storage,
        ttl: const Duration(seconds: 10),
        bindAddress: InternetAddress.loopbackIPv4,
      );

      expect(server.isClosed, isFalse);
      await server.close();
      expect(server.isClosed, isTrue);

      // Subsequent close calls must not throw
      await expectLater(server.close(), completes);
      await expectLater(server.close(force: false), completes);
    });
  });
}

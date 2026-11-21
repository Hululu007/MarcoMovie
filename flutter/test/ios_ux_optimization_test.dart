import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cast_avatar_service.dart';
import 'package:marco_movie/core/cast_service.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/curated_discovery.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/apple_theme.dart';
import 'package:marco_movie/ui/cast_avatar_section.dart';
import 'package:marco_movie/ui/curated_discovery_section.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/favorite_postcard_animation.dart';
import 'package:marco_movie/ui/ios_liquid_glass.dart';
import 'package:marco_movie/ui/mobile_player_chrome.dart';
import 'package:marco_movie/ui/player/ios_cast_panel.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player/start_spec_overlay.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(minutes: 4);
  Duration durationValue = const Duration(minutes: 42);
  double volumeValue = 100.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();

  @override
  Playlist get playlist => playlistValue;
  @override
  bool get playing => playingValue;
  @override
  bool get completed => completedValue;
  @override
  Duration get position => positionValue;
  @override
  Duration get duration => durationValue;
  @override
  double get volume => volumeValue;
  @override
  double get rate => rateValue;
  @override
  bool get buffering => bufferingValue;
  @override
  Tracks get tracks => tracksValue;
  @override
  Track get track => trackValue;
}

class _FakePlayerStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast();
  final heightCtrl = StreamController<int?>.broadcast();
  final trackCtrl = StreamController<Track>.broadcast();
  final tracksCtrl = StreamController<Tracks>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final bufferingCtrl = StreamController<bool>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();

  @override
  Stream<int?> get width => widthCtrl.stream;
  @override
  Stream<int?> get height => heightCtrl.stream;
  @override
  Stream<Track> get track => trackCtrl.stream;
  @override
  Stream<Tracks> get tracks => tracksCtrl.stream;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<Duration> get duration => durationCtrl.stream;
  @override
  Stream<bool> get playing => playingCtrl.stream;
  @override
  Stream<bool> get buffering => bufferingCtrl.stream;
  @override
  Stream<bool> get completed => completedCtrl.stream;
  @override
  Stream<String> get error => errorCtrl.stream;

  Future<void> close() async {
    await Future.wait([
      widthCtrl.close(),
      heightCtrl.close(),
      trackCtrl.close(),
      tracksCtrl.close(),
      positionCtrl.close(),
      durationCtrl.close(),
      playingCtrl.close(),
      bufferingCtrl.close(),
      completedCtrl.close(),
      errorCtrl.close(),
    ]);
  }
}

class _FakePlayer extends Fake implements Player {
  final _FakePlayerState _state = _FakePlayerState();
  final _FakePlayerStream _stream = _FakePlayerStream();
  bool disposed = false;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) _state.playlistValue = Playlist([playable]);
    _state.playingValue = play;
    _state.bufferingValue = false;
    if (!disposed) {
      _stream.widthCtrl.add(3840);
      _stream.heightCtrl.add(2160);
      _stream.durationCtrl.add(_state.durationValue);
      _stream.positionCtrl.add(_state.positionValue);
      _stream.bufferingCtrl.add(false);
      _stream.playingCtrl.add(play);
    }
  }

  @override
  Future<void> play() async {
    _state.playingValue = true;
    if (!disposed) _stream.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    _state.playingValue = false;
    if (!disposed) _stream.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    _state.playingValue = !_state.playingValue;
    if (!disposed) _stream.playingCtrl.add(_state.playingValue);
  }

  @override
  Future<void> seek(Duration d) async {
    _state.positionValue = d;
    if (!disposed) _stream.positionCtrl.add(d);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double v) async => _state.volumeValue = v;
  @override
  Future<void> stop() async => _state.playingValue = false;

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testSite = CmsSite(
    key: 'ux_site',
    name: '测试片源',
    type: 1,
    api: 'https://source.example/api',
    isPrivate: true,
  );
  const testVideo = CmsVideo(
    id: 'ux_vid_1',
    title: '兰香如故（臻彩）',
    year: '2026',
    area: '中国大陆',
    actor: '谭松韵, 刘学义, 李梦',
    description: '一段跨越山海与朝堂风云的传奇故事。',
    lines: [
      CmsLine(
        name: '百度网盘 1',
        episodes: [
          CmsEpisode(
            name: 'S01E01.mkv',
            url: 'file:///tmp/ux_e1.mp4',
          ),
          CmsEpisode(
            name: 'S01E02.mkv',
            url: 'file:///tmp/ux_e2.mp4',
          ),
        ],
      ),
      CmsLine(
        name: '夸克原画',
        episodes: [
          CmsEpisode(name: '第01集', url: 'file:///tmp/ux_q1.mp4'),
        ],
      ),
    ],
  );

  tearDown(() {
    IosLiquidGlassBridge.setAvailableForTest(null);
    IosLiquidGlassBridge.setReduceTransparencyForTest(null);
    GlassworkBackdrop.reduceTransparency.value = false;
    GlassworkBackdrop.intensity.value = 0.68;
    AppleTheme.mode.value = ThemeMode.system;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosLiquidGlassBridge.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobilePlayerChrome.iosSystemChromeChannel, null);
  });

  testWidgets(
    'Req 1, 2, 3, 4, 5, 7: compact spec badges, unified low bottom deck, left lock button, 4 top-right actions, anchored popover & animated HUD toggle',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      IosLiquidGlassBridge.setAvailableForTest(true);
      final channelCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        channelCalls.add(call);
        if (call.method == 'showOptionSheet') return null;
        return null;
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(844, 390);
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _FakePlayer();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      // Emit audio codec so both 4K & AAC micro-badges appear.
      player._stream.trackCtrl.add(
        const Track(
          video: VideoTrack('1', 'hevc', 'hevc', codec: 'hevc'),
          audio: AudioTrack('1', 'aac', 'aac', codec: 'aac'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Req 1: Spec badges shrink-wrap tightly (NOT stretched full-width bars!)
      final pills = find.byType(SpecBadgePill);
      expect(pills, findsWidgets);
      for (final elem in pills.evaluate()) {
        final size = elem.size!;
        expect(size.width, lessThan(96.0), reason: 'Spec badge must stay compact');
        expect(size.height, lessThanOrEqualTo(24.0));
      }

      // Req 2: Progress bar & toolbar are fused into ONE compact bottom deck
      final dockRect = tester.getRect(
        find.byKey(const Key('ios-player-primary-dock')),
      );
      final scrubberRect = tester.getRect(
        find.byKey(const Key('player-progress-bar')),
      );
      expect(dockRect.contains(scrubberRect.center), isTrue);
      expect(dockRect.height, lessThanOrEqualTo(82.0));

      // Req 3: Lock button sits independently on the left edge (NOT inside bottom dock)
      final lockRect = tester.getRect(
        find.byKey(const Key('player-lock-button')),
      );
      expect(lockRect.left, lessThan(80.0));
      expect(dockRect.contains(lockRect.center), isFalse);
      expect(lockRect.center.dy, closeTo(195.0, 28.0));

      // Req 5 & Round 2 Feedback 3: Top-right has Cast, Favorite, Download in order,
      // while More sits cleanly inside the lowered bottom toolbar dock.
      final castRect = tester.getRect(
        find.byKey(const Key('ios-player-cast-button')),
      );
      final favRect = tester.getRect(
        find.byKey(const Key('ios-player-favorite-button')),
      );
      final dlRect = tester.getRect(
        find.byKey(const Key('ios-player-download-button')),
      );
      final moreRect = tester.getRect(
        find.byKey(const Key('ios-player-more-button')),
      );
      expect(castRect.right, lessThan(favRect.left));
      expect(favRect.right, lessThan(dlRect.left));
      expect(dockRect.contains(moreRect.center), isTrue);
      expect(dockRect.bottom, greaterThan(375.0));

      // Req 4: Tapping More sends anchorRect to native Liquid Glass popover
      await tester.tap(find.byKey(const Key('ios-player-more-button')));
      await tester.pump(const Duration(milliseconds: 80));
      final moreCall = channelCalls.firstWhere((c) => c.method == 'showOptionSheet');
      final args = Map<dynamic, dynamic>.from(moreCall.arguments as Map);
      expect(args['anchorRect'], isNotNull);

      // Req 4 (Flutter popover): Tapping Lines opens compact anchored bubble (not full-screen!)
      await tester.tap(find.byKey(const ValueKey('ios-dock-action-lines')));
      await tester.pumpAndSettle();
      final bubbleRect = tester.getRect(
        find.byKey(const Key('ios-glass-popover-bubble')),
      );
      expect(bubbleRect.width, lessThanOrEqualTo(310.0));
      expect(bubbleRect.height, lessThan(340.0));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Req 7: Tapping screen triggers smooth HUD hide animation (still fading at 60ms, unmounted after 220ms)
      await tester.tapAt(const Offset(420, 120));
      await tester.pump(const Duration(milliseconds: 280)); // settle single-tap delay
      // Now HUD starts 180ms fade-out -> mid-fade at 60ms
      await tester.pump(const Duration(milliseconds: 60));
      final fadeWidget = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byKey(const Key('player-hud-animated-visibility')),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fadeWidget.opacity.value, lessThan(1.0));
      expect(fadeWidget.opacity.value, greaterThan(0.0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(IosPlayerChrome), findsNothing);
      expect(find.byType(GlassworkBackdrop), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'Req 6: DLNA XML/SSDP/SOAP parsing + 爱优腾-style cast popover and remote stage',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. Pure-Dart DLNA XML & SSDP parsing
      const ssdp =
          'HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:49152/desc.xml\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n';
      expect(
        CastController.extractSsdpHeader(ssdp, 'location'),
        'http://127.0.0.1:49152/desc.xml',
      );
      const xml = '''
<root><device>
  <friendlyName>客厅小米电视 4K</friendlyName>
  <modelName>MiTV-AX</modelName>
  <UDN>uuid:mitv-01</UDN>
  <serviceList>
    <service>
      <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
      <controlURL>/upnp/control/AVTransport1</controlURL>
    </service>
    <service>
      <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
      <controlURL>/upnp/control/RenderingControl1</controlURL>
    </service>
  </serviceList>
</device></root>''';
      final dev = CastController.parseDeviceDescriptionXml(
        xml,
        'http://127.0.0.1:49152/desc.xml',
      );
      expect(dev, isNotNull);
      expect(dev!.name, '客厅小米电视 4K');
      expect(
        dev.avTransportControlUrl,
        'http://127.0.0.1:49152/upnp/control/AVTransport1',
      );
      expect(CastController.formatDlnaTime(const Duration(minutes: 12, seconds: 5)), '00:12:05');
      expect(CastController.parseDlnaTime('01:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));

      // 2. Cast Popover UI shows both AirPlay and discovered DLNA TV
      final controller = CastController()..setDevicesForTest([dev]);
      addTearDown(controller.dispose);
      CastDevice? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => showIosCastPopover(
                    context: ctx,
                    anchorRect: const Rect.fromLTWH(300, 40, 36, 36),
                    controller: controller,
                    onSelectDevice: (d) async => selected = d,
                  ),
                  child: const Text('打开投屏'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开投屏'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ios-cast-airplay-row')), findsOneWidget);
      expect(find.byKey(const Key('ios-cast-manual-ip-row')), findsOneWidget);
      expect(find.text('客厅小米电视 4K'), findsOneWidget);
      await tester.tap(find.text('客厅小米电视 4K'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'uuid:mitv-01');

      // 3. Active Casting Remote Stage renders controls cleanly
      var exited = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: IosCastingRemoteStage(
              controller: controller,
              episodeLabel: 'S01E01 · 百度网盘 1',
              onBack: () {},
              onSwitchDevice: () {},
              onExitCast: () => exited = true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('ios-casting-remote-stage')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ios-cast-exit-button')));
      expect(exited, isTrue);
    },
  );

  test(
    'Req 6b: Dual-mode DLNA helpers (subnet, interface filter, URLBase, DIDL-Lite) + live manual probe & LAN relay',
    () async {
      // 1. Private LAN & interface filter helpers
      final sampleHomeIp = ['192', '168', '1', '88'].join('.');
      final sampleSubnetIp = ['192', '168', '31', '42'].join('.');
      expect(CastController.isPrivateLanIpv4(sampleHomeIp), isTrue);
      expect(CastController.isPrivateLanIpv4('10.0.0.5'), isTrue);
      expect(CastController.isPrivateLanIpv4('172.20.10.2'), isTrue);
      expect(CastController.isPrivateLanIpv4('127.0.0.1'), isFalse);
      expect(CastController.isPrivateLanIpv4('8.8.8.8'), isFalse);

      expect(CastController.isSkippedInterfaceName('utun3'), isTrue);
      expect(CastController.isSkippedInterfaceName('pdp_ip0'), isTrue);
      expect(CastController.isSkippedInterfaceName('awdl0'), isTrue);
      expect(CastController.isSkippedInterfaceName('en0'), isFalse);
      expect(CastController.isSkippedInterfaceName('wlan0'), isFalse);

      final peers = CastController.buildSubnetScanIps(sampleSubnetIp);
      expect(peers.length, 253);
      expect(peers.contains(sampleSubnetIp), isFalse);
      expect(peers.contains(['192', '168', '31', '1'].join('.')), isTrue);
      expect(peers.contains(['192', '168', '31', '254'].join('.')), isTrue);

      // 2. Manual target parser & URLBase / DIDL-Lite helpers
      expect(CastController.parseManualTargetInput(sampleHomeIp)?.host, sampleHomeIp);
      final withPort = CastController.parseManualTargetInput('$sampleHomeIp:18652');
      expect(withPort?.host, sampleHomeIp);
      expect(withPort?.port, 18652);

      final sampleTvBase = Uri(
        scheme: 'http',
        host: sampleHomeIp,
        port: 18652,
      ).toString();
      final urlBaseXml = '''
<root>
  <URLBase>$sampleTvBase</URLBase>
  <device>
    <u:friendlyName>Marco Movie 客厅电视</u:friendlyName>
    <modelName>Marco Movie TV</modelName>
    <UDN>uuid:marco-tv-01</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/dlna/control/AVTransport</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final parsedTv = CastController.parseDeviceDescriptionXml(
        urlBaseXml,
        '$sampleTvBase/dlna/device.xml',
      );
      expect(parsedTv?.name, 'Marco Movie 客厅电视');
      expect(
        parsedTv?.avTransportControlUrl,
        '$sampleTvBase/dlna/control/AVTransport',
      );

      final didl = CastController.buildDidlLiteMetadata(
        title: '星际穿越 · 第1集',
        mediaUrl: Uri(
          scheme: 'http',
          host: '10.0.0.20',
          port: 5555,
          path: '/video.m3u8',
        ).toString(),
      );
      expect(didl, contains('星际穿越 · 第1集'));
      expect(didl, contains('application/vnd.apple.mpegurl'));

      // 3. Live loopback end-to-end test: manual probe + SetAVTransportURI + LAN media relay
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      String? capturedUri;
      String? capturedMeta;
      String? capturedReferer;
      final mockTv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final mockUpstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await mockTv.close(force: true);
        await mockUpstream.close(force: true);
      });

      mockTv.listen((req) async {
        if (req.uri.path == '/dlna/device.xml') {
          req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
          req.response.write('''
<root><device>
  <friendlyName>Marco Movie 测试电视</friendlyName>
  <modelName>Marco Movie TV</modelName>
  <UDN>uuid:live-test-tv</UDN>
  <serviceList>
    <service>
      <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
      <controlURL>/dlna/control/AVTransport</controlURL>
    </service>
  </serviceList>
</device></root>''');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/dlna/control/AVTransport') {
          final body = await utf8.decoder.bind(req).join();
          if (body.contains('SetAVTransportURI')) {
            capturedUri = CastController.extractXmlTag(body, 'CurrentURI');
            capturedMeta = CastController.extractXmlTag(body, 'CurrentURIMetaData');
          }
          req.response.statusCode = 200;
          req.response.write('<s:Envelope><s:Body/></s:Envelope>');
          await req.response.close();
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      mockUpstream.listen((req) async {
        capturedReferer = req.headers.value('referer');
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        req.response.add(utf8.encode('FAKE-MP4-STREAM'));
        await req.response.close();
      });

      final controller = CastController();
      addTearDown(controller.dispose);

      // Simulate user pasting Marco Movie TV's web cast URL `http://127.0.0.1:<port>/cast/abc`
      final found = await controller.probeManualTarget(
        'http://127.0.0.1:${mockTv.port}/cast/abcdef1234',
      );
      expect(found, isNotNull);
      expect(found!.name, 'Marco Movie 测试电视');

      // Cast a loopback proxy URL with custom Referer header -> relay must expose & proxy it!
      final ok = await controller.castToDevice(
        device: found,
        mediaUrl: 'http://127.0.0.1:${mockUpstream.port}/stream.mp4',
        title: '测试影片',
        headers: const {'Referer': 'https://example.test/watch'},
      );
      expect(ok, isTrue);
      expect(capturedUri, isNotNull);
      expect(capturedUri, isNot(contains('127.0.0.1:${mockUpstream.port}')));
      expect(capturedUri, contains('/s/'));
      expect(capturedMeta, contains('测试影片'));

      // Fetch the relayed URL as if we were the TV -> verifies headers & payload forwarded!
      final tvClient = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() => tvClient.close(force: true));
      final relayReq = await tvClient.getUrl(Uri.parse(capturedUri!));
      final relayResp = await relayReq.close();
      expect(relayResp.statusCode, 200);
      final bytes = await utf8.decoder.bind(relayResp).join();
      expect(bytes, 'FAKE-MP4-STREAM');
      expect(capturedReferer, 'https://example.test/watch');

      await controller.stopCasting();
    },
  );

  testWidgets(
    'Req 8: iOS Portrait opens Tencent-Video companion mode (top 16:9 box + title/intro/cast avatars/episodes) with fullscreen toggle & physical auto-rotation',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final chromeCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MobilePlayerChrome.iosSystemChromeChannel,
              (call) async {
        chromeCalls.add(call);
        return null;
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _FakePlayer();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      // Top 16:9 video box + scrollable companion sheet below
      final boxRect = tester.getRect(
        find.byKey(const Key('ios-portrait-video-box')),
      );
      expect(boxRect.width, closeTo(390.0, 1.0));
      expect(boxRect.height, closeTo(390.0 * 9 / 16, 1.5));
      expect(find.byKey(const Key('ios-portrait-companion-sheet')), findsOneWidget);
      expect(find.text('兰香如故（臻彩）'), findsWidgets);
      expect(find.byKey(const Key('cast-avatar-section')), findsOneWidget);
      expect(find.text('谭松韵'), findsOneWidget);
      expect(find.byKey(const Key('ios-portrait-episode-1')), findsOneWidget);

      // Tapping fullscreen button requests landscape orientation
      await tester.tap(
        find.byKey(const Key('ios-portrait-companion-fullscreen-btn')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        chromeCalls.any(
          (c) => c.method == 'requestOrientation' && c.arguments == 'landscape',
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'Req 9 & 11: Curated Rex discovery renders 6 shelves, DetailScreen shows avatar cast list, and curated playback strictly uses user-added sources only',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. All 6 Rex-style modules exist in CuratedDiscoverySection
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CuratedDiscoverySection(
                hasUserSources: false,
                loadLive: false,
                onOpenVideo: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('全部专题'), findsOneWidget);
      for (final spec in CuratedDiscoveryService.modules) {
        expect(find.byKey(Key('curated-module-${spec.id}')), findsOneWidget);
        expect(find.text(spec.title), findsAtLeastNWidgets(1));
      }

      // 2. DetailScreen opened from curated card with ZERO user sources -> cannot play!
      SharedPreferences.setMockInitialValues({});
      final emptyStorage = await StorageService.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            site: CuratedDiscoveryService.curatedSiteSentinel,
            initialVideo: const CmsVideo(
              id: 'curated:db:1',
              title: '星际穿越',
              year: '2014',
              actor: '马修·麦康纳, 安妮·海瑟薇',
            ),
            client: CmsClient(
              client: MockClient((_) async => http.Response('{"list":[]}', 200)),
            ),
            storage: emptyStorage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('cast-avatar-section')), findsOneWidget);
      expect(find.byKey(const Key('curated-no-source-card')), findsOneWidget);
      expect(find.text('暂无片源资源 · 无法播放'), findsOneWidget);

      // 3. CastAvatarSection standalone parses & displays circular cast items
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CastAvatarSection(
              title: '星际穿越',
              initialMembers: [
                CastMember(name: '马修·麦康纳', role: '库珀'),
                CastMember(name: '安妮·海瑟薇', role: '布兰德'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('马修·麦康纳'), findsOneWidget);
      expect(find.text('安妮·海瑟薇'), findsOneWidget);
    },
  );

  testWidgets(
    'Req 10: Light/Dark auto-system theme defaults to system & Liquid Glass intensity slider updates live',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      expect(storage.appThemeMode, 'system');
      expect(AppleTheme.fromPref(storage.appThemeMode), ThemeMode.system);

      await storage.setAppThemeMode('light');
      expect(storage.appThemeMode, 'light');
      expect(AppleTheme.fromPref(storage.appThemeMode), ThemeMode.light);

      // Verify ApplePalette resolves soft warm pearl-mist canvas + pearl cards in light mode & true black in dark mode
      expect(ApplePalette.light.background, const Color(0xFFE9ECF2));
      expect(ApplePalette.light.groupedPrimary, const Color(0xFFF8F9FC));
      expect(ApplePalette.dark.background, const Color(0xFF000000));

      // Verify IosNativeSlider responds to tap on track (fixes hard-to-tap bug!)
      IosLiquidGlassBridge.setAvailableForTest(false);
      double sliderVal = 0.2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: IosNativeSlider(
                  value: sliderVal,
                  onChanged: (v) => sliderVal = v,
                ),
              ),
            ),
          ),
        ),
      );
      final sliderRect = tester.getRect(find.byType(IosNativeSlider));
      // Tap near 80% along the slider track
      await tester.tapAt(
        Offset(sliderRect.left + sliderRect.width * 0.8, sliderRect.center.dy),
      );
      await tester.pump();
      expect(sliderVal, greaterThan(0.65));
    },
  );

  testWidgets(
    'Req 12: Favorite triggers retro camera flash -> 4:3 Marco branded postcard -> Dynamic Island feedback',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final feedbackPhases = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosLiquidGlassBridge.channel, (call) async {
        if (call.method == 'triggerFavoriteDynamicIslandFeedback') {
          final phase = call.arguments is String
              ? call.arguments as String
              : ((call.arguments as Map?)?['phase'] ?? '').toString();
          feedbackPhases.add(phase);
          return <String, dynamic>{
            'hasDynamicIsland': true,
            'islandX': 132.0,
            'islandTop': 11.0,
            'islandWidth': 126.0,
            'islandHeight': 37.0,
          };
        }
        return null;
      });

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () {
                    FavoritePostcardFlightOverlay.show(
                      ctx,
                      title: '星际穿越',
                      year: '2014',
                    );
                  },
                  child: const Text('收藏'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('收藏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Shutter triggered + 4:3 branded postcard visible with MARCO stamp
      expect(feedbackPhases, contains('shutter'));
      expect(find.byKey(const Key('favorite-postcard-card')), findsOneWidget);
      expect(
        find.byKey(const Key('favorite-postcard-brand-stamp')),
        findsOneWidget,
      );
      final cardSize = tester.getSize(
        find.byKey(const Key('favorite-postcard-card')),
      );
      expect(cardSize.width / cardSize.height, closeTo(4 / 3, 0.05));

      // Advance into Dynamic Island arrival & elastic expansion phase
      await tester.pump(const Duration(milliseconds: 900));
      expect(feedbackPhases, contains('arrive'));
      expect(
        find.byKey(const Key('favorite-dynamic-island-feedback')),
        findsOneWidget,
      );

      // Animation completes and cleans up overlay cleanly
      await tester.pump(const Duration(milliseconds: 1400));
      expect(
        find.byKey(const Key('favorite-dynamic-island-feedback')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Real-device polish regressions: Light Mode contrast, Douban Rexxar credits items schema, frosted portrait companion, and HUD stays visible while popover is open',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      // 1. Soft pearl Light Mode palette & AppleGroupedTile render dark legible ink on soothing pearl canvas
      expect(ApplePalette.light.background.computeLuminance(), greaterThan(0.75));
      expect(ApplePalette.light.background.computeLuminance(), lessThan(0.92));
      expect(ApplePalette.light.labelPrimary.computeLuminance(), lessThan(0.05));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: AppleGroupedSection(
              header: '浅色测试分组',
              children: [
                AppleGroupedTile(
                  icon: Icons.palette,
                  title: '浅色标题可读性',
                  subtitle: '副标题同样清晰可见',
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final titleWidget = tester.widget<Text>(find.text('浅色标题可读性'));
      expect(titleWidget.style!.color, ApplePalette.light.labelPrimary);

      // 2. Douban Rexxar flat `items` schema parsing + role cleanup + http/webp upgrade
      final parsedCast = CastAvatarService.parseDoubanCreditsPayload({
        'items': [
          {
            'name': '代露娃',
            'character': '主演 Actor',
            'avatar': {
              'large': 'http://img3.doubanio.com/view/personage/m/public/demo.webp',
            },
          },
          {
            'name': '郭锋',
            'character': '导演 Director',
            'avatar': {
              'normal': 'https://img3.doubanio.com/view/personage/m/public/dir.jpg',
            },
          },
        ],
      });
      expect(parsedCast, hasLength(2));
      expect(parsedCast.first.name, '代露娃');
      expect(parsedCast.first.role, '主演');
      expect(
        parsedCast.first.avatarUrl,
        'https://img3.doubanio.com/view/personage/m/public/demo.jpg',
      );
      expect(parsedCast[1].role, '导演');

      // 3. Player HUD MUST NOT auto-hide while a Liquid Glass popover is open (4.5s > 3.5s)
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final storage = await initTestStorage();
      final prefs = PlayerHudPrefs.inMemory(isDesktop: false);
      addTearDown(prefs.dispose);
      final player = _FakePlayer();
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            site: testSite,
            video: testVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: storage,
            debugPlayer: player,
            debugVideoSurface: const ColoredBox(color: Colors.black),
            debugHudPrefs: prefs,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(IosPlayerChrome), findsOneWidget);

      // Open Lines popover bubble
      await tester.tap(find.byKey(const ValueKey('ios-dock-action-lines')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ios-glass-popover-bubble')), findsOneWidget);

      // Wait 4.5s (> 3.5s auto-hide delay) -> HUD MUST still stay visible!
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.byType(IosPlayerChrome), findsOneWidget);

      // Dismiss popover -> HUD resumes auto-hide cleanly
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );
}

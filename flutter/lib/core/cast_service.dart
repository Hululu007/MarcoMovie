import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../ui/ios_liquid_glass.dart';

/// A discovered DLNA / UPnP MediaRenderer on the local network.
class CastDevice {
  final String id;
  final String name;
  final String model;
  final String host;
  final String location;
  final String avTransportControlUrl;
  final String? renderingControlUrl;

  const CastDevice({
    required this.id,
    required this.name,
    required this.model,
    required this.host,
    required this.location,
    required this.avTransportControlUrl,
    this.renderingControlUrl,
  });

  String get subtitle => model.isNotEmpty ? '$model · $host' : host;
}

enum CastSessionState {
  idle,
  connecting,
  playing,
  paused,
  error,
}

/// Pure-Dart DLNA/UPnP discovery + SOAP playback controller, plus native iOS
/// AirPlay route picker trigger.
class CastController extends ChangeNotifier {
  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _avTransportService =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const String _renderingControlService =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  final List<CastDevice> _devices = [];
  bool _scanning = false;
  CastDevice? _activeDevice;
  CastSessionState _state = CastSessionState.idle;
  String? _statusMessage;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _volume = 60;
  String _currentMediaUrl = '';
  String _currentTitle = '';
  Timer? _pollTimer;
  bool _disposed = false;

  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get scanning => _scanning;
  CastDevice? get activeDevice => _activeDevice;
  CastSessionState get state => _state;
  String? get statusMessage => _statusMessage;
  Duration get position => _position;
  Duration get duration => _duration;
  int get volume => _volume;
  String get currentTitle => _currentTitle;
  bool get isCasting =>
      _activeDevice != null &&
      (_state == CastSessionState.connecting ||
          _state == CastSessionState.playing ||
          _state == CastSessionState.paused);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Resolves a local LAN IPv4 address so loopback proxy URLs (127.0.0.1) can
  /// be rewritten when a smart TV needs to reach this device on Wi-Fi.
  static Future<String?> resolveLanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback && !ip.startsWith('169.254.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Rewrites `127.0.0.1` / `localhost` URLs to the device's LAN IPv4 if
  /// available, leaving remote HTTP(S) stream URLs untouched.
  static Future<String> resolveCastableUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return rawUrl.trim();
    final host = uri.host.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost') {
      final lanIp = await resolveLanIpv4();
      if (lanIp != null && lanIp.isNotEmpty) {
        return uri.replace(host: lanIp).toString();
      }
    }
    return rawUrl.trim();
  }

  /// Opens the native iOS AirPlay route picker (`AVRoutePickerView`).
  Future<bool> openAirPlayPicker() async {
    return IosLiquidGlassBridge.presentAirPlayPicker();
  }

  /// Sends SSDP M-SEARCH multicast probes on the LAN to discover DLNA TVs and
  /// set-top boxes (爱优腾-style 投屏设备列表).
  Future<void> scanDevices({
    Duration timeout = const Duration(milliseconds: 2600),
    bool clearExisting = false,
  }) async {
    if (_scanning) return;
    _scanning = true;
    _statusMessage = null;
    if (clearExisting) {
      _devices.clear();
    }
    _notify();

    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _scanning = false;
      _notify();
      return;
    }

    final seenLocations = <String>{};
    final discovered = List<CastDevice>.of(_devices);
    RawDatagramSocket? socket;
    Timer? scanTimer;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      final completer = Completer<void>();
      final pendingFetches = <Future<void>>[];

      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final dg = socket?.receive();
          if (dg == null) return;
          final text = utf8.decode(dg.data, allowMalformed: true);
          final location = extractSsdpHeader(text, 'location');
          if (location == null || !seenLocations.add(location)) return;
          pendingFetches.add(
            _fetchDeviceDescription(location).then((dev) {
              if (dev == null) return;
              if (!discovered.any((d) => d.id == dev.id)) {
                discovered.add(dev);
                _devices
                  ..clear()
                  ..addAll(discovered);
                _notify();
              }
            }),
          );
        },
        onError: (Object err) {
          _statusMessage = '局域网搜索受限，请确认已开启本地网络权限并连接同一 Wi-Fi';
          debugPrint('DLNA socket error: $err');
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );

      final target = InternetAddress(_ssdpAddress);
      for (final st in const [
        'urn:schemas-upnp-org:service:AVTransport:1',
        'urn:schemas-upnp-org:device:MediaRenderer:1',
      ]) {
        final payload = buildSsdpSearchPayload(st);
        try {
          socket.send(utf8.encode(payload), target, _ssdpPort);
        } catch (e) {
          _statusMessage = '局域网搜索受限，请确认已开启本地网络权限并连接同一 Wi-Fi';
          debugPrint('DLNA send error: $e');
        }
      }

      scanTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
      if (pendingFetches.isNotEmpty) {
        await Future.wait(pendingFetches)
            .timeout(const Duration(seconds: 2), onTimeout: () => const []);
      }
      _devices
        ..clear()
        ..addAll(discovered);
    } catch (e) {
      _statusMessage = '局域网搜索受限，请确认已开启本地网络权限并连接同一 Wi-Fi';
      debugPrint('DLNA scan error: $e');
    } finally {
      scanTimer?.cancel();
      socket?.close();
      _scanning = false;
      _notify();
    }
  }

  /// Injects mock or manually discovered devices (helpful in tests or manual setup).
  void setDevicesForTest(List<CastDevice> list) {
    _devices
      ..clear()
      ..addAll(list);
    _notify();
  }

  /// Starts casting [mediaUrl] to [device] using UPnP `SetAVTransportURI` + `Play`.
  Future<bool> castToDevice({
    required CastDevice device,
    required String mediaUrl,
    required String title,
    Duration initialPosition = Duration.zero,
    Duration totalDuration = Duration.zero,
  }) async {
    _pollTimer?.cancel();
    _activeDevice = device;
    _currentTitle = title;
    _position = initialPosition;
    _duration = totalDuration;
    _state = CastSessionState.connecting;
    _statusMessage = '正在连接 ${device.name}…';
    _notify();

    try {
      final castUrl = await resolveCastableUrl(mediaUrl);
      _currentMediaUrl = castUrl;

      final setUriBody = '''
<u:SetAVTransportURI xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <CurrentURI>${escapeXml(castUrl)}</CurrentURI>
  <CurrentURIMetaData></CurrentURIMetaData>
</u:SetAVTransportURI>''';

      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'SetAVTransportURI',
        bodyXml: setUriBody,
      );

      const playBody = '''
<u:Play xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <Speed>1</Speed>
</u:Play>''';
      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'Play',
        bodyXml: playBody,
      );

      if (initialPosition > const Duration(seconds: 2)) {
        unawaited(seek(initialPosition));
      }

      _state = CastSessionState.playing;
      _statusMessage = '已投屏到 ${device.name}';
      _startPositionPolling();
      _notify();
      return true;
    } catch (e) {
      _state = CastSessionState.error;
      _statusMessage = '投屏失败：请确认设备支持该视频格式且在同一 Wi-Fi';
      debugPrint('DLNA cast error: $e');
      _notify();
      return false;
    }
  }

  /// Switches the currently casting episode/stream without dropping the TV session.
  Future<bool> switchMedia({
    required String mediaUrl,
    required String title,
    Duration totalDuration = Duration.zero,
  }) async {
    final device = _activeDevice;
    if (device == null) return false;
    return castToDevice(
      device: device,
      mediaUrl: mediaUrl,
      title: title,
      initialPosition: Duration.zero,
      totalDuration: totalDuration,
    );
  }

  Future<void> togglePlayPause() async {
    final device = _activeDevice;
    if (device == null) return;
    final nextPlaying = _state != CastSessionState.playing;
    try {
      if (nextPlaying) {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Play',
          bodyXml:
              '<u:Play xmlns:u="$_avTransportService"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>',
        );
        _state = CastSessionState.playing;
      } else {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Pause',
          bodyXml:
              '<u:Pause xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:Pause>',
        );
        _state = CastSessionState.paused;
      }
      _notify();
    } catch (_) {}
  }

  Future<void> seek(Duration target) async {
    final device = _activeDevice;
    if (device == null) return;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (_duration > Duration.zero && target > _duration ? _duration : target);
    _position = clamped;
    _notify();
    try {
      await _sendSoapAction(
        controlUrl: device.avTransportControlUrl,
        serviceType: _avTransportService,
        action: 'Seek',
        bodyXml: '''
<u:Seek xmlns:u="$_avTransportService">
  <InstanceID>0</InstanceID>
  <Unit>REL_TIME</Unit>
  <Target>${formatDlnaTime(clamped)}</Target>
</u:Seek>''',
      );
    } catch (_) {}
  }

  Future<void> adjustVolume(int delta) async {
    final device = _activeDevice;
    final next = (_volume + delta).clamp(0, 100);
    _volume = next;
    _notify();
    final rcUrl = device?.renderingControlUrl;
    if (rcUrl == null || rcUrl.isEmpty) return;
    try {
      await _sendSoapAction(
        controlUrl: rcUrl,
        serviceType: _renderingControlService,
        action: 'SetVolume',
        bodyXml: '''
<u:SetVolume xmlns:u="$_renderingControlService">
  <InstanceID>0</InstanceID>
  <Channel>Master</Channel>
  <DesiredVolume>$next</DesiredVolume>
</u:SetVolume>''',
      );
    } catch (_) {}
  }

  Future<void> stopCasting() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final device = _activeDevice;
    _activeDevice = null;
    _state = CastSessionState.idle;
    _statusMessage = null;
    _currentMediaUrl = '';
    _notify();
    if (device != null) {
      try {
        await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'Stop',
          bodyXml:
              '<u:Stop xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:Stop>',
        );
      } catch (_) {}
    }
  }

  void _startPositionPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final device = _activeDevice;
      if (device == null || _state == CastSessionState.idle) return;
      try {
        final xml = await _sendSoapAction(
          controlUrl: device.avTransportControlUrl,
          serviceType: _avTransportService,
          action: 'GetPositionInfo',
          bodyXml:
              '<u:GetPositionInfo xmlns:u="$_avTransportService"><InstanceID>0</InstanceID></u:GetPositionInfo>',
        );
        final relTime = extractXmlTag(xml, 'RelTime');
        final trackDuration = extractXmlTag(xml, 'TrackDuration');
        final parsedPos = parseDlnaTime(relTime);
        final parsedDur = parseDlnaTime(trackDuration);
        if (parsedPos != null) _position = parsedPos;
        if (parsedDur != null && parsedDur > Duration.zero) {
          _duration = parsedDur;
        }
        _notify();
      } catch (_) {
        if (_state == CastSessionState.playing &&
            _duration > Duration.zero &&
            _position < _duration) {
          _position += const Duration(seconds: 2);
          _notify();
        }
      }
    });
  }

  Future<CastDevice?> _fetchDeviceDescription(String location) async {
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.hasScheme) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 2));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = await utf8.decoder.bind(resp).join();
      return parseDeviceDescriptionXml(body, location);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _sendSoapAction({
    required String controlUrl,
    required String serviceType,
    required String action,
    required String bodyXml,
  }) async {
    final uri = Uri.parse(controlUrl);
    final envelope = buildSoapEnvelope(bodyXml);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', '"$serviceType#$action"');
      final bytes = utf8.encode(envelope);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await utf8.decoder.bind(resp).join();
      if (resp.statusCode >= 400) {
        throw HttpException('SOAP $action failed (${resp.statusCode})');
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  /// Builds an SSDP M-SEARCH packet for [searchTarget].
  static String buildSsdpSearchPayload(String searchTarget) {
    return 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $searchTarget\r\n'
        '\r\n';
  }

  /// Extracts a case-insensitive header value from an SSDP response datagram.
  static String? extractSsdpHeader(String raw, String headerName) {
    final target = '${headerName.toLowerCase()}:';
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      if (line.toLowerCase().startsWith(target)) {
        final v = line.substring(target.length).trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// Parses a UPnP MediaRenderer description XML document into a [CastDevice].
  static CastDevice? parseDeviceDescriptionXml(String xml, String location) {
    final baseUri = Uri.tryParse(location);
    if (baseUri == null) return null;
    final friendlyName = extractXmlTag(xml, 'friendlyName') ?? baseUri.host;
    final modelName = extractXmlTag(xml, 'modelName') ?? '';
    final udn = extractXmlTag(xml, 'UDN') ?? location;
    final avPath = _extractServiceControlUrl(xml, 'AVTransport');
    if (avPath == null || avPath.isEmpty) return null;
    final rcPath = _extractServiceControlUrl(xml, 'RenderingControl');
    return CastDevice(
      id: udn,
      name: friendlyName,
      model: modelName,
      host: baseUri.host,
      location: location,
      avTransportControlUrl: baseUri.resolve(avPath).toString(),
      renderingControlUrl:
          rcPath != null && rcPath.isNotEmpty ? baseUri.resolve(rcPath).toString() : null,
    );
  }

  static String? _extractServiceControlUrl(String xml, String serviceKeyword) {
    final serviceRe = RegExp(
      r'<service\b[^>]*>([\s\S]*?)</service>',
      caseSensitive: false,
    );
    for (final match in serviceRe.allMatches(xml)) {
      final block = match.group(1) ?? '';
      if (!block.contains(serviceKeyword)) continue;
      final control = extractXmlTag(block, 'controlURL');
      if (control != null && control.isNotEmpty) return control;
    }
    return null;
  }

  static String? extractXmlTag(String xml, String tag) {
    final re = RegExp(
      '<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    );
    final m = re.firstMatch(xml);
    return m?.group(1)?.trim();
  }

  static String buildSoapEnvelope(String bodyXml) {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>$bodyXml</s:Body>'
        '</s:Envelope>';
  }

  static String escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String formatDlnaTime(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 359999);
    final h = (totalSec ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static Duration? parseDlnaTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final clean = raw.split('.').first.trim();
    final parts = clean.split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return Duration(hours: h, minutes: m, seconds: s);
  }

  String get currentMediaUrl => _currentMediaUrl;

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}

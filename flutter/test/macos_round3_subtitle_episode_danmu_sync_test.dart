// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/container_metadata_reader.dart';
import 'package:marco_movie/core/danmu/dandanplay_provider.dart';
import 'package:marco_movie/core/danmu/danmu_prefs.dart';
import 'package:marco_movie/core/danmu/danmu_source_sync.dart';
import 'package:marco_movie/core/danmu/provider.dart';
import 'package:marco_movie/core/emby_library.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/series_scraper.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/subtitle_layout.dart';
import 'package:marco_movie/ui/cloud_sync_panel.dart';
import 'package:marco_movie/ui/danmu/danmu_layer.dart';
import 'package:marco_movie/ui/danmu/danmu_settings_sheet.dart';
import 'package:marco_movie/ui/onboarding/onboarding_prefs.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player/slim_progress_bar.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/series_scrape_sheet.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_storage_helper.dart';

class _AllowLocalHttpOverrides extends HttpOverrides {}

IOClient _createRealLoopbackIoClient() {
  final raw = _AllowLocalHttpOverrides().createHttpClient(null)
    ..idleTimeout = Duration.zero;
  return IOClient(raw);
}

/// Alternates FakeAsync microtask/frame flushes with real OS socket I/O yields
/// so multi-step sequential loopback HTTP flows (GET -> PUT -> GET -> PUT or
/// match -> openSession -> comment) settle deterministically inside testWidgets.
Future<void> _pumpRealNetwork(
  WidgetTester tester, {
  int rounds = 10,
  int realDelayMs = 35,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: realDelayMs)),
    );
  }
  await tester.pump(const Duration(milliseconds: 50));
}

// ---------------------------------------------------------------------------
// Isolated in-memory SharedPreferences so two user profiles (A & B) can
// execute genuinely concurrent WebDAV syncs in parallel inside one process.
// ---------------------------------------------------------------------------
class _IsolatedSharedPreferences implements SharedPreferences {
  final Map<String, Object> _store;

  _IsolatedSharedPreferences([Map<String, Object>? initial])
      : _store = <String, Object>{...?initial};

  @override
  Set<String> getKeys() => Set<String>.from(_store.keys);

  @override
  Object? get(String key) => _store[key];

  @override
  bool? getBool(String key) => _store[key] as bool?;

  @override
  int? getInt(String key) => _store[key] as int?;

  @override
  double? getDouble(String key) => _store[key] as double?;

  @override
  String? getString(String key) => _store[key] as String?;

  @override
  bool containsKey(String key) => _store.containsKey(key);

  @override
  List<String>? getStringList(String key) {
    final v = _store[key];
    if (v is List) return v.cast<String>().toList();
    return null;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _store[key] = List<String>.from(value);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _store.remove(key);
    return true;
  }

  @override
  Future<bool> commit() async => true;

  @override
  Future<bool> clear() async {
    _store.clear();
    return true;
  }

  @override
  Future<void> reload() async {}
}

// ---------------------------------------------------------------------------
// Fake media_kit Player capturing native mpv properties & opened media URLs.
// ---------------------------------------------------------------------------
class _Round3FakePlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = true;
  bool completedValue = false;
  Duration positionValue = const Duration(seconds: 2);
  Duration durationValue = const Duration(minutes: 24);
  double volumeValue = 80.0;
  double rateValue = 1.0;
  bool bufferingValue = false;
  Tracks tracksValue = const Tracks();
  Track trackValue = const Track();
  int? widthValue = 1280;
  int? heightValue = 720;

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
  @override
  int? get width => widthValue;
  @override
  int? get height => heightValue;
}

class _Round3FakePlayerStream extends Fake implements PlayerStream {
  final widthCtrl = StreamController<int?>.broadcast(sync: true);
  final heightCtrl = StreamController<int?>.broadcast(sync: true);
  final trackCtrl = StreamController<Track>.broadcast(sync: true);
  final tracksCtrl = StreamController<Tracks>.broadcast(sync: true);
  final positionCtrl = StreamController<Duration>.broadcast(sync: true);
  final durationCtrl = StreamController<Duration>.broadcast(sync: true);
  final playingCtrl = StreamController<bool>.broadcast(sync: true);
  final bufferingCtrl = StreamController<bool>.broadcast(sync: true);
  final completedCtrl = StreamController<bool>.broadcast(sync: true);
  final errorCtrl = StreamController<String>.broadcast(sync: true);
  final volumeCtrl = StreamController<double>.broadcast(sync: true);

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
  @override
  Stream<double> get volume => volumeCtrl.stream;

  Future<void> close() => Future.wait([
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
        volumeCtrl.close(),
      ]);
}

class _Round3FakePlatformPlayer extends Fake implements PlatformPlayer {
  final Map<String, String> properties = <String, String>{};
  final List<({String key, String value})> propertyHistory =
      <({String key, String value})>[];
  String? Function(String key)? dynamicPropertyReader;

  Future<void> setProperty(String key, String value) async {
    properties[key] = value;
    propertyHistory.add((key: key, value: value));
  }

  Future<String?> getProperty(String key) async {
    final dyn = dynamicPropertyReader?.call(key);
    if (dyn != null) return dyn;
    return properties[key];
  }
}

class _Round3FakePlayer extends Fake implements Player {
  final _Round3FakePlayerState stateImpl = _Round3FakePlayerState();
  final _Round3FakePlayerStream streamImpl = _Round3FakePlayerStream();
  final _Round3FakePlatformPlayer platformImpl = _Round3FakePlatformPlayer();
  final List<String> openedUris = <String>[];
  final Map<String, Map<String, String>> metadataByUri =
      <String, Map<String, String>>{};
  bool _disposed = false;

  _Round3FakePlayer() {
    platformImpl.dynamicPropertyReader = (key) {
      if (key == 'metadata') {
        final uri = openedUris.isNotEmpty ? openedUris.last : '';
        final meta = metadataByUri[uri];
        if (meta != null && meta.isNotEmpty) {
          return jsonEncode(meta);
        }
        return '{}';
      }
      if (key == 'media-title') {
        final uri = openedUris.isNotEmpty ? openedUris.last : '';
        return metadataByUri[uri]?['title'] ?? '';
      }
      return null;
    };
  }

  @override
  PlatformPlayer? get platform => platformImpl;
  @override
  PlayerState get state => stateImpl;
  @override
  PlayerStream get stream => streamImpl;

  void setActiveSubtitleTrack(
    SubtitleTrack track, {
    List<SubtitleTrack>? available,
  }) {
    if (available != null) {
      stateImpl.tracksValue = Tracks(subtitle: available);
      if (!_disposed) streamImpl.tracksCtrl.add(stateImpl.tracksValue);
    }
    stateImpl.trackValue = Track(subtitle: track);
    if (!_disposed) streamImpl.trackCtrl.add(stateImpl.trackValue);
  }

  void emitPosition(Duration d) {
    stateImpl.positionValue = d;
    if (!_disposed) streamImpl.positionCtrl.add(d);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      openedUris.add(playable.uri);
      stateImpl.playlistValue = Playlist([playable]);
    }
    stateImpl.playingValue = play;
    stateImpl.bufferingValue = false;
    if (stateImpl.durationValue == Duration.zero) {
      stateImpl.durationValue = const Duration(minutes: 24);
    }
    stateImpl.positionValue = const Duration(seconds: 2);
    if (!_disposed) {
      streamImpl.durationCtrl.add(stateImpl.durationValue);
      streamImpl.widthCtrl.add(stateImpl.widthValue);
      streamImpl.heightCtrl.add(stateImpl.heightValue);
      streamImpl.playingCtrl.add(play);
      streamImpl.bufferingCtrl.add(false);
      streamImpl.positionCtrl.add(stateImpl.positionValue);
      streamImpl.tracksCtrl.add(stateImpl.tracksValue);
      streamImpl.trackCtrl.add(stateImpl.trackValue);
    }
  }

  @override
  Future<void> play() async {
    stateImpl.playingValue = true;
    if (!_disposed) streamImpl.playingCtrl.add(true);
  }

  @override
  Future<void> pause() async {
    stateImpl.playingValue = false;
    if (!_disposed) streamImpl.playingCtrl.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (stateImpl.playingValue) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration d) async {
    stateImpl.positionValue = d;
    if (!_disposed) streamImpl.positionCtrl.add(d);
  }

  @override
  Future<void> setVolume(double v) async {
    stateImpl.volumeValue = v;
    if (!_disposed) streamImpl.volumeCtrl.add(v);
  }

  @override
  Future<void> setRate(double r) async {
    stateImpl.rateValue = r;
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    stateImpl.trackValue = Track(subtitle: track);
    if (!_disposed) streamImpl.trackCtrl.add(stateImpl.trackValue);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}

  @override
  Future<void> stop() async {
    stateImpl.playingValue = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await streamImpl.close();
  }
}

// ---------------------------------------------------------------------------
// Pure-Dart minimal Matroska (MKV) binary synthesizer for container tag tests.
// ---------------------------------------------------------------------------
Uint8List _ebmlVintSize(int len) {
  if (len < 0x7F) return Uint8List.fromList(<int>[0x80 | len]);
  if (len < 0x3FFF) {
    return Uint8List.fromList(<int>[0x40 | (len >> 8), len & 0xFF]);
  }
  return Uint8List.fromList(<int>[
    0x20 | (len >> 16),
    (len >> 8) & 0xFF,
    len & 0xFF,
  ]);
}

Uint8List _ebmlElement(List<int> id, List<int> payload) {
  final out = BytesBuilder(copy: false);
  out.add(id);
  out.add(_ebmlVintSize(payload.length));
  out.add(payload);
  return out.toBytes();
}

Uint8List _buildMkvWithContainerTags({
  required String infoTitle,
  required Map<String, String> simpleTags,
}) {
  final header = _ebmlElement(
    const <int>[0x1A, 0x45, 0xDF, 0xA3],
    _ebmlElement(const <int>[0x42, 0x82], utf8.encode('matroska')),
  );
  final info = _ebmlElement(
    const <int>[0x15, 0x49, 0xA9, 0x66],
    _ebmlElement(const <int>[0x7B, 0xA9], utf8.encode(infoTitle)),
  );
  final tagChildren = BytesBuilder(copy: false);
  for (final e in simpleTags.entries) {
    final st = BytesBuilder(copy: false)
      ..add(_ebmlElement(const <int>[0x45, 0xA3], utf8.encode(e.key)))
      ..add(_ebmlElement(const <int>[0x44, 0x87], utf8.encode(e.value)));
    tagChildren.add(_ebmlElement(const <int>[0x67, 0xC8], st.toBytes()));
  }
  final tag = _ebmlElement(const <int>[0x73, 0x73], tagChildren.toBytes());
  final tags = _ebmlElement(const <int>[0x12, 0x54, 0xC3, 0x67], tag);
  final segPayload = BytesBuilder(copy: false)
    ..add(info)
    ..add(tags);
  final segment = _ebmlElement(
    const <int>[0x18, 0x53, 0x80, 0x67],
    segPayload.toBytes(),
  );
  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(segment))
      .toBytes();
}

// ---------------------------------------------------------------------------
// Real local HTTP WebDAV server with strict ETag / If-Match / If-None-Match
// ---------------------------------------------------------------------------
class _LocalWebdavServer {
  late final HttpServer _server;
  final Map<String, ({Uint8List body, String etag})> files =
      <String, ({Uint8List body, String etag})>{};
  final List<Map<String, dynamic>> requestLog = <Map<String, dynamic>>[];
  int? failDanmuStatusCode;
  int conflict412Count = 0;
  bool forceOneConcurrent412OnNextDanmuPut = false;

  int get port => _server.port;
  String baseUrlForFile(String fileName) =>
      'http://127.0.0.1:$port/dav/$fileName';

  static String _etagFor(List<int> bytes) =>
      '"${sha256.convert(bytes).toString().substring(0, 16)}"';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method.toUpperCase();
    final isDanmu = path.toLowerCase().endsWith('.danmu.json');
    final bodyBytes =
        await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));

    if (isDanmu && failDanmuStatusCode != null) {
      requestLog.add(<String, dynamic>{
        'method': method,
        'path': path,
        'status': failDanmuStatusCode,
        'note': 'injected_failure',
      });
      req.response.statusCode = failDanmuStatusCode!;
      await req.response.close();
      return;
    }

    if (method == 'MKCOL') {
      requestLog.add(<String, dynamic>{
        'method': method,
        'path': path,
        'status': 201,
      });
      req.response.statusCode = 201;
      await req.response.close();
      return;
    }

    if (method == 'GET') {
      final entry = files[path];
      if (entry == null) {
        requestLog.add(<String, dynamic>{
          'method': method,
          'path': path,
          'status': 404,
        });
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      requestLog.add(<String, dynamic>{
        'method': method,
        'path': path,
        'status': 200,
        'etag': entry.etag,
      });
      req.response.statusCode = 200;
      req.response.headers.set('ETag', entry.etag);
      req.response.headers.contentType = ContentType.json;
      req.response.add(entry.body);
      await req.response.close();
      return;
    }

    if (method == 'PUT') {
      final existing = files[path];
      final ifMatch = req.headers.value('if-match')?.trim();
      final ifNoneMatch = req.headers.value('if-none-match')?.trim();

      if (isDanmu && forceOneConcurrent412OnNextDanmuPut) {
        forceOneConcurrent412OnNextDanmuPut = false;
        conflict412Count++;
        requestLog.add(<String, dynamic>{
          'method': method,
          'path': path,
          'status': 412,
          'ifMatch': ifMatch,
          'note': 'concurrent_race_412',
        });
        req.response.statusCode = 412;
        await req.response.close();
        return;
      }

      if (ifNoneMatch == '*' && existing != null) {
        conflict412Count++;
        requestLog.add(<String, dynamic>{
          'method': method,
          'path': path,
          'status': 412,
          'ifNoneMatch': '*',
        });
        req.response.statusCode = 412;
        await req.response.close();
        return;
      }
      if (ifMatch != null &&
          ifMatch.isNotEmpty &&
          (existing == null || existing.etag != ifMatch)) {
        conflict412Count++;
        requestLog.add(<String, dynamic>{
          'method': method,
          'path': path,
          'status': 412,
          'ifMatch': ifMatch,
          'currentEtag': existing?.etag,
        });
        req.response.statusCode = 412;
        await req.response.close();
        return;
      }

      final bytes = Uint8List.fromList(bodyBytes);
      final nextEtag = _etagFor(bytes);
      final created = existing == null;
      files[path] = (body: bytes, etag: nextEtag);
      requestLog.add(<String, dynamic>{
        'method': method,
        'path': path,
        'status': created ? 201 : 204,
        'ifMatch': ifMatch,
        'ifNoneMatch': ifNoneMatch,
        'etag': nextEtag,
      });
      req.response.statusCode = created ? 201 : 204;
      req.response.headers.set('ETag', nextEtag);
      await req.response.close();
      return;
    }

    req.response.statusCode = 405;
    await req.response.close();
  }
}

// ---------------------------------------------------------------------------
// Real local HTTP Dandanplay-compatible Danmu Server (scrambled match order,
// neighbor-only mode, custom subpath, and optional auth-header verification).
// ---------------------------------------------------------------------------
class _LocalDanmuServer {
  late final HttpServer _server;
  final String subpath;
  final bool requireAuthHeaders;
  final bool neighborOnlyMode;
  int responseDelayMs = 0;
  final List<String> requestedMatchFileNames = <String>[];
  final List<String> requestedCommentIds = <String>[];

  _LocalDanmuServer({
    this.subpath = '',
    this.requireAuthHeaders = false,
    this.neighborOnlyMode = false,
  });

  int get port => _server.port;
  String get originUrl => 'http://127.0.0.1:$port$subpath';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    if (responseDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: responseDelayMs));
    }
    if (requireAuthHeaders) {
      final appId = req.headers.value('x-appid') ?? '';
      final sig = req.headers.value('x-signature') ?? '';
      if (appId.isEmpty || sig.isEmpty) {
        req.response.statusCode = 401;
        req.response.write(jsonEncode({'errorMessage': 'missing auth'}));
        await req.response.close();
        return;
      }
    }

    final prefix = subpath;
    final path = req.uri.path;
    if (prefix.isNotEmpty && !path.startsWith(prefix)) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final relPath = prefix.isEmpty ? path : path.substring(prefix.length);

    if (relPath == '/api/v2/match' && req.method.toUpperCase() == 'POST') {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final fileName = (body['fileName'] ?? '').toString();
      requestedMatchFileNames.add(fileName);

      final List<Map<String, dynamic>> matches;
      if (neighborOnlyMode) {
        // Deliberately return ONLY neighbors (E09 and E11) when E10 is queried!
        matches = <Map<String, dynamic>>[
          {
            'episodeId': 20009,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第9集 前夜',
          },
          {
            'episodeId': 20011,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第11集 余波',
          },
        ];
      } else {
        // Deliberately SCRAMBLED server response order:
        // S01E10 first, S02E02 second, S02E05 third, S02E07 fourth, S02E10 LAST!
        matches = <Map<String, dynamic>>[
          {
            'episodeId': 10010,
            'animeId': 9001,
            'animeTitle': '星际测试物语 第一季',
            'episodeTitle': '第10集 第一季终章',
          },
          {
            'episodeId': 20002,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第2集 启程',
          },
          {
            'episodeId': 20005,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第5集 迷雾',
          },
          {
            'episodeId': 20007,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第7集 反转',
          },
          {
            'episodeId': 20010,
            'animeId': 9002,
            'animeTitle': '星际测试物语 第二季',
            'episodeTitle': '第10集 第二季高潮',
          },
        ];
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'isMatched': true, 'matches': matches}));
      await req.response.close();
      return;
    }

    if (relPath.startsWith('/api/v2/comment/')) {
      final rawId = relPath.substring('/api/v2/comment/'.length);
      requestedCommentIds.add(rawId);
      final comments = <Map<String, dynamic>>[
        {
          'cid': 1000 + (int.tryParse(rawId) ?? 0),
          'p': '2.00,1,16777215,u1',
          'm': 'EP-$rawId 精准弹幕 @2s',
        },
        {
          'cid': 2000 + (int.tryParse(rawId) ?? 0),
          'p': '45.50,1,16777215,u2',
          'm': 'EP-$rawId 精准弹幕 @45s',
        },
        {
          'cid': 3000 + (int.tryParse(rawId) ?? 0),
          'p': '90.50,1,16777215,u3',
          'm': 'EP-$rawId 精准弹幕 @90s',
        },
      ];
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'count': comments.length, 'comments': comments}));
      await req.response.close();
      return;
    }

    req.response.statusCode = 404;
    await req.response.close();
  }
}

Future<bool> _tryLoadVerificationSystemFont() async {
  // Load CupertinoIcons so real Apple icons render cleanly in exported PNGs.
  try {
    final cupertinoBytes = await rootBundle.load(
      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    );
    final iconLoader = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(Future<ByteData>.value(cupertinoBytes));
    await iconLoader.load();
  } catch (_) {}

  final candidates = <String>[
    if (Platform.isMacOS) ...[
      '/System/Library/Fonts/PingFang.ttc',
      '/System/Library/Fonts/Hiragino Sans GB.ttc',
      '/System/Library/Fonts/STHeiti Medium.ttc',
      '/System/Library/Fonts/STHeiti Light.ttc',
      '/System/Library/Fonts/Supplemental/Songti.ttc',
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      '/System/Library/Fonts/Helvetica.ttc',
    ],
    if (Platform.isWindows) ...[
      r'C:\Windows\Fonts\msyh.ttc',
      r'C:\Windows\Fonts\simhei.ttf',
      r'C:\Windows\Fonts\arial.ttf',
    ],
    if (Platform.isLinux) ...[
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ],
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader('VerifyFont')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      return true;
    } catch (_) {}
  }
  return false;
}

Future<void> _captureRepaintBoundaryPng(
  WidgetTester tester,
  GlobalKey boundaryKey,
  File outFile,
) async {
  await tester.runAsync(() async {
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(byteData!.buffer.asUint8List());
  });
}

void main() {
  final artifactsDirPath =
      (Platform.environment['MARCOMOVIE_VERIFY_ARTIFACTS_DIR'] ?? '').trim();
  final mpvFramesDirPath =
      (Platform.environment['MARCOMOVIE_MPV_FRAMES_DIR'] ?? '').trim();

  // =========================================================================
  // ITEM 1: Bottom HUD Subtitle Lift (Text + ASS + PGS, Narrow + Fullscreen)
  // =========================================================================
  group('Item 1: Bottom HUD Subtitle Lift & Stability', () {
    test('SubtitleLayoutGeometry classifies tracks & computes padding/sub-pos', () {
      expect(
        SubtitleLayoutGeometry.classifyTrack(SubtitleTrack.no()),
        SubtitleRenderMode.none,
      );
      expect(
        SubtitleLayoutGeometry.classifyTrack(
          SubtitleTrack('1', '中英双语', 'zh', codec: 'subrip'),
        ),
        SubtitleRenderMode.flutterTextOverlay,
      );
      expect(
        SubtitleLayoutGeometry.classifyTrack(
          SubtitleTrack('2', '特效字幕', 'zh', codec: 'ass'),
        ),
        SubtitleRenderMode.mpvNativeAss,
      );
      expect(
        SubtitleLayoutGeometry.classifyTrack(
          SubtitleTrack(
            '3',
            'Blu-ray PGS',
            'zh',
            codec: 'hdmv_pgs_subtitle',
            image: true,
          ),
        ),
        SubtitleRenderMode.mpvNativeBitmap,
      );

      // Dereference SubtitleTrack.auto() via live mpv sid.
      final tracks = <SubtitleTrack>[
        SubtitleTrack.auto(),
        SubtitleTrack.no(),
        SubtitleTrack('1', 'SRT', 'zh', codec: 'subrip'),
        SubtitleTrack('2', 'ASS', 'zh', codec: 'ass', isDefault: true),
        SubtitleTrack('3', 'PGS', 'zh', codec: 'hdmv_pgs_subtitle', image: true),
      ];
      expect(
        SubtitleLayoutGeometry.resolveActiveTrack(
          selected: SubtitleTrack.auto(),
          available: tracks,
          mpvSid: '3',
        )?.id,
        '3',
      );

      // Baseline padding when hidden or slim-progress-only.
      expect(
        SubtitleLayoutGeometry.computeTextOverlayBottomPadding(
          hudControlsVisible: false,
          measuredBottomBarHeight: 96,
        ),
        SubtitleLayoutGeometry.defaultBottomPadding,
      );
      // Lifted padding when controls visible.
      expect(
        SubtitleLayoutGeometry.computeTextOverlayBottomPadding(
          hudControlsVisible: true,
          measuredBottomBarHeight: 96,
        ),
        greaterThanOrEqualTo(96 + SubtitleLayoutGeometry.defaultHudClearanceGap),
      );

      // Narrow 900x600 & Fullscreen 1440x900 sub-pos math.
      final subPosNarrow = SubtitleLayoutGeometry.computeMpvSubPos(
        viewport: const Size(900, 600),
        videoWidth: 1280,
        videoHeight: 720,
        fit: BoxFit.contain,
        hudControlsVisible: true,
        measuredBottomBarHeight: 96,
      );
      final subPosFull = SubtitleLayoutGeometry.computeMpvSubPos(
        viewport: const Size(1440, 900),
        videoWidth: 1280,
        videoHeight: 720,
        fit: BoxFit.contain,
        hudControlsVisible: true,
        measuredBottomBarHeight: 96,
      );
      expect(subPosNarrow, inInclusiveRange(70, 92));
      expect(subPosFull, inInclusiveRange(80, 95));
      expect(
        SubtitleLayoutGeometry.computeMpvSubPos(
          viewport: const Size(900, 600),
          videoWidth: 1280,
          videoHeight: 720,
          fit: BoxFit.contain,
          hudControlsVisible: false,
          measuredBottomBarHeight: 96,
        ),
        100,
      );
      // Ultrawide 2160x900 crop (BoxFit.cover) playing 1280x720 must compute
      // sub-pos from the full unclipped scaled video height (2160x1215, 157.5px
      // bottom crop):
      // - HUD shown/dragging (86px bar + 16px gap) -> sub-pos == 78
      // - HUD hidden/re-hidden (24px baseline above visible bottom) -> sub-pos == 85
      expect(
        SubtitleLayoutGeometry.computeMpvSubPos(
          viewport: const Size(2160, 900),
          videoWidth: 1280,
          videoHeight: 720,
          fit: BoxFit.cover,
          hudControlsVisible: true,
          measuredBottomBarHeight: 86,
        ),
        78,
      );
      expect(
        SubtitleLayoutGeometry.computeMpvSubPos(
          viewport: const Size(2160, 900),
          videoWidth: 1280,
          videoHeight: 720,
          fit: BoxFit.cover,
          hudControlsVisible: false,
          measuredBottomBarHeight: 86,
        ),
        85,
      );
    });

    for (final viewportCase in const <({
      String label,
      Size size,
      BoxFit fit,
      String aspectMode,
      String frameTag,
      int? exactSubPos,
      int expectedHiddenSubPos,
      String assHiddenFrame,
      String pgsHiddenFrame,
    })>[
      (
        label: 'narrow_900x600',
        size: Size(900, 600),
        fit: BoxFit.contain,
        aspectMode: 'contain',
        frameTag: 'narrow',
        exactSubPos: null,
        expectedHiddenSubPos: 100,
        assHiddenFrame: 'mpv_ass_pos100.png',
        pgsHiddenFrame: 'mpv_pgs_pos100.png',
      ),
      (
        label: 'fullscreen_1440x900',
        size: Size(1440, 900),
        fit: BoxFit.contain,
        aspectMode: 'contain',
        frameTag: 'fullscreen',
        exactSubPos: null,
        expectedHiddenSubPos: 100,
        assHiddenFrame: 'mpv_ass_pos100.png',
        pgsHiddenFrame: 'mpv_pgs_pos100.png',
      ),
      (
        label: 'fullscreen_crop_2160x900',
        size: Size(2160, 900),
        fit: BoxFit.cover,
        aspectMode: 'cover',
        frameTag: 'crop_2160x900',
        exactSubPos: 78,
        expectedHiddenSubPos: 85,
        assHiddenFrame: 'mpv_ass_hidden_crop_2160x900.png',
        pgsHiddenFrame: 'mpv_pgs_hidden_crop_2160x900.png',
      ),
    ]) {
      testWidgets(
        'PlayerScreen lifts 2-line subtitle above bottom controls in ${viewportCase.label} for hidden/shown/dragging/slim-progress while keeping video, danmu & drag region stable',
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
        timeout: const Timeout(Duration(seconds: 60)),
        (tester) async {
          final hasRealFont = artifactsDirPath.isNotEmpty
              ? (await tester.runAsync(_tryLoadVerificationSystemFont) ?? false)
              : false;

          tester.view.physicalSize = viewportCase.size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final storage = await initTestStorage(
            initialPrefs: <String, Object>{
              OnboardingPrefs.playHintDismissedKey: true,
              OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
              StorageService.keyDefaultAspectMode: viewportCase.aspectMode,
            },
          );
          const winChannel = MethodChannel('window_manager');
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(winChannel, (call) async {
            if (call.method == 'isFullScreen') {
              return viewportCase.label.startsWith('fullscreen');
            }
            return null;
          });
          addTearDown(() {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(winChannel, null);
          });
          final player = _Round3FakePlayer();
          player.stateImpl.durationValue = const Duration(seconds: 5);
          player.stateImpl.positionValue = const Duration(seconds: 2);

          final srtTrack = SubtitleTrack(
            '1',
            '可选双行文字字幕 (SRT)',
            'zh',
            codec: 'subrip',
            isDefault: true,
          );
          final assTrack = SubtitleTrack(
            '2',
            'ASS 顶部标识+双行底字幕',
            'zh',
            codec: 'ass',
          );
          final pgsTrack = SubtitleTrack(
            '3',
            'Blu-ray PGS 图像字幕',
            'zh',
            codec: 'hdmv_pgs_subtitle',
            image: true,
          );
          final allSubTracks = <SubtitleTrack>[
            SubtitleTrack.auto(),
            SubtitleTrack.no(),
            srtTrack,
            assTrack,
            pgsTrack,
          ];
          player.setActiveSubtitleTrack(srtTrack, available: allSubTracks);

          // Optional real Mpv.framework-rendered frame image notifier for PNG evidence.
          // Pre-decode PNGs synchronously via decodeImageFromList + RawImage so
          // RepaintBoundary captures never lag by 1 async decode frame.
          final videoFrameNotifier = ValueNotifier<ui.Image?>(null);

          Future<void> setMpvFrame(String name) async {
            if (mpvFramesDirPath.isEmpty) return;
            final f = File('$mpvFramesDirPath/$name');
            if (!f.existsSync()) return;
            final bytes = f.readAsBytesSync();
            final decoded = await tester.runAsync(
              () => decodeImageFromList(bytes),
            );
            final prev = videoFrameNotifier.value;
            videoFrameNotifier.value = decoded;
            await tester.pump();
            prev?.dispose();
          }

          await setMpvFrame('mpv_video_only.png');

          final boundaryKey = GlobalKey();
          const site = CmsSite(
            key: 'local_mkv',
            name: '本地片源',
            type: 1,
            api: 'https://local.invalid/api',
          );
          final subDir = Directory.systemTemp.createTempSync('marco_sub_test_');
          addTearDown(() => subDir.deleteSync(recursive: true));
          final dummyMkvPath = '${subDir.path}/subtitle_verify.mkv';
          File(dummyMkvPath).writeAsBytesSync(const <int>[0, 1, 2, 3]);

          final video = CmsVideo(
            id: 'mkv_sub_verify',
            title: 'MKV 字幕对照测试片',
            lines: <CmsLine>[
              CmsLine(
                name: 'MKV主线',
                episodes: <CmsEpisode>[
                  CmsEpisode(
                    name: 'S02E10 字幕实测',
                    url: Uri.file(dummyMkvPath).toString(),
                  ),
                ],
              ),
            ],
          );

          const twoLineSubtitleKey = Key('test-two-line-subtitle-box');
          final showTextSubNotifier = ValueNotifier<bool>(true);
          addTearDown(showTextSubNotifier.dispose);

          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  brightness: Brightness.dark,
                  platform: TargetPlatform.macOS,
                  fontFamily: hasRealFont ? 'VerifyFont' : null,
                  cupertinoOverrideTheme: CupertinoThemeData(
                    brightness: Brightness.dark,
                    textTheme: CupertinoTextThemeData(
                      textStyle: TextStyle(
                        fontFamily: hasRealFont ? 'VerifyFont' : null,
                      ),
                      actionTextStyle: TextStyle(
                        fontFamily: hasRealFont ? 'VerifyFont' : null,
                      ),
                    ),
                  ),
                  useMaterial3: true,
                ),
                home: PlayerScreen(
                  site: site,
                  video: video,
                  initialLineIndex: 0,
                  initialEpisodeIndex: 0,
                  storage: storage,
                  debugPlayer: player,
                  debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
                  debugOnboardingPrefs: OnboardingPrefs(
                    _IsolatedSharedPreferences(const <String, Object>{
                      OnboardingPrefs.playHintDismissedKey: true,
                      OnboardingPrefs.doneVersionKey:
                          OnboardingPrefs.currentVersion,
                    }),
                  ),
                  debugDanmuSettings: const DanmuSettings(enabled: false),
                  debugVideoSurface: ValueListenableBuilder<ui.Image?>(
                    valueListenable: videoFrameNotifier,
                    builder: (_, image, __) {
                      if (image != null) {
                        return ColoredBox(
                          color: Colors.black,
                          child: SizedBox.expand(
                            child: ClipRect(
                              child: FittedBox(
                                fit: viewportCase.fit,
                                child: RawImage(image: image),
                              ),
                            ),
                          ),
                        );
                      }
                      return const ColoredBox(color: Color(0xFF102030));
                    },
                  ),
                  debugSubtitleLayer: ValueListenableBuilder<bool>(
                    valueListenable: showTextSubNotifier,
                    builder: (_, visible, __) {
                      if (!visible) return const SizedBox.shrink();
                      return Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          key: twoLineSubtitleKey,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '第一行可选文字字幕：底部控件出现时整体上移\n第二行双行字幕最下沿必须高于控件上沿 (t=00:02)',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              height: 1.32,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );

          await tester.pump(const Duration(milliseconds: 250));
          await tester.pump(const Duration(milliseconds: 250));

          final videoRectShown =
              tester.getRect(find.byKey(const Key('player-video-surface-layer')));
          final danmuRectShown =
              tester.getRect(find.byKey(const Key('player-danmu-layer')));
          final gestureRectShown =
              tester.getRect(find.byKey(const Key('player-video-stack')));

          // --- State B: Controls Shown (woken by mouse hover / initial HUD) ---
          final controlsFinder =
              find.byKey(const Key('desktop-player-bottom-controls'));
          expect(controlsFinder, findsOneWidget);
          final controlsRectShown = tester.getRect(controlsFinder);
          final subRectShown = tester.getRect(find.byKey(twoLineSubtitleKey));

          // Lowest line of 2-line subtitle MUST sit strictly above controls top edge!
          expect(
            subRectShown.bottom,
            lessThan(controlsRectShown.top),
            reason:
                '${viewportCase.label} controls shown: subtitle bottom ${subRectShown.bottom} must be < controls top ${controlsRectShown.top}',
          );

          if (artifactsDirPath.isNotEmpty) {
            await _captureRepaintBoundaryPng(
              tester,
              boundaryKey,
              File(
                '$artifactsDirPath/subtitle_text_${viewportCase.label}_2_shown.png',
              ),
            );
          }

          // --- State C: Dragging Progress Slider at the same playback timestamp (00:02) ---
          final sliderFinder = find.byType(Slider);
          expect(sliderFinder, findsOneWidget);
          final sliderRect = tester.getRect(sliderFinder);
          final thumbAtTwoSec = Offset(
            sliderRect.left + sliderRect.width * 0.40,
            sliderRect.center.dy,
          );
          final dragGesture = await tester.startGesture(thumbAtTwoSec);
          await tester.pump(const Duration(milliseconds: 50));
          await dragGesture.moveBy(const Offset(10, 0));
          await tester.pump(const Duration(milliseconds: 250));

          final controlsRectDrag = tester.getRect(controlsFinder);
          final subRectDrag = tester.getRect(find.byKey(twoLineSubtitleKey));
          expect(
            subRectDrag.bottom,
            lessThan(controlsRectDrag.top),
            reason:
                '${viewportCase.label} dragging progress: subtitle bottom ${subRectDrag.bottom} must stay < controls top ${controlsRectDrag.top}',
          );
          expect(
            tester.getRect(find.byKey(const Key('player-video-surface-layer'))),
            videoRectShown,
          );
          expect(
            tester.getRect(find.byKey(const Key('player-danmu-layer'))),
            danmuRectShown,
          );
          expect(
            tester.getRect(find.byKey(const Key('player-video-stack'))),
            gestureRectShown,
          );

          if (artifactsDirPath.isNotEmpty) {
            await _captureRepaintBoundaryPng(
              tester,
              boundaryKey,
              File(
                '$artifactsDirPath/subtitle_text_${viewportCase.label}_3_dragging.png',
              ),
            );
          }

          await dragGesture.up();
          await tester.pump(const Duration(milliseconds: 100));

          // --- State A / D: Wait for controls auto-hide (only SlimProgressBar remains) ---
          await tester.pump(const Duration(milliseconds: 3600));
          await tester.pump(const Duration(milliseconds: 450));

          expect(controlsFinder, findsNothing);
          expect(find.byType(SlimProgressBar), findsOneWidget);
          final subRectHidden = tester.getRect(find.byKey(twoLineSubtitleKey));
          // Subtitle returned to baseline (much lower than when controls were shown).
          expect(
            subRectHidden.bottom,
            greaterThan(subRectShown.bottom + 50),
            reason:
                '${viewportCase.label} hidden/slim-progress: subtitle should restore to baseline',
          );
          // Video frame, danmu layer, and drag region remained completely stable.
          expect(
            tester.getRect(find.byKey(const Key('player-video-surface-layer'))),
            videoRectShown,
          );
          expect(
            tester.getRect(find.byKey(const Key('player-danmu-layer'))),
            danmuRectShown,
          );
          expect(
            tester.getRect(find.byKey(const Key('player-video-stack'))),
            gestureRectShown,
          );

          if (artifactsDirPath.isNotEmpty) {
            await _captureRepaintBoundaryPng(
              tester,
              boundaryKey,
              File(
                '$artifactsDirPath/subtitle_text_${viewportCase.label}_1_hidden_slim.png',
              ),
            );
          }

          // Wake controls again via mouse hover -> subtitle lifts again!
          final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: const Offset(40, 40));
          await mouse.moveTo(
            Offset(viewportCase.size.width / 2, viewportCase.size.height / 2),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(controlsFinder, findsOneWidget);
          final subRectRewoken = tester.getRect(find.byKey(twoLineSubtitleKey));
          expect(subRectRewoken.bottom, lessThan(tester.getRect(controlsFinder).top));

          // --- Verify native libmpv ASS & PGS continuous 4-state transition:
          //     1_hidden_slim -> 2_shown -> 3_dragging -> 4_rehidden_slim ---
          final sizeTag = viewportCase.frameTag;
          for (final nativeCase in <({
            String kind,
            SubtitleTrack track,
            String hiddenFrame,
            String liftedFrame,
          })>[
            (
              kind: 'ass',
              track: assTrack,
              hiddenFrame: viewportCase.assHiddenFrame,
              liftedFrame: 'mpv_ass_lifted_$sizeTag.png',
            ),
            (
              kind: 'pgs',
              track: pgsTrack,
              hiddenFrame: viewportCase.pgsHiddenFrame,
              liftedFrame: 'mpv_pgs_lifted_$sizeTag.png',
            ),
          ]) {
            showTextSubNotifier.value = false;
            player.setActiveSubtitleTrack(nativeCase.track);
            await tester.pump(const Duration(milliseconds: 120));
            await tester.pump(const Duration(milliseconds: 120));

            expect(player.platformImpl.properties['sub-ass'], 'yes');
            expect(player.platformImpl.properties['sub-ass-override'], 'yes');
            expect(player.platformImpl.properties['sub-visibility'], 'yes');

            // 1. Hidden (initial slim-progress baseline):
            await tester.pump(const Duration(milliseconds: 3600));
            await tester.pump(const Duration(milliseconds: 450));
            expect(controlsFinder, findsNothing);
            expect(
              player.platformImpl.properties['sub-pos'],
              '${viewportCase.expectedHiddenSubPos}',
              reason:
                  '${nativeCase.kind} in ${viewportCase.label} initial hidden state must use cropped-visible baseline ${viewportCase.expectedHiddenSubPos}',
            );
            if (artifactsDirPath.isNotEmpty) {
              await setMpvFrame(nativeCase.hiddenFrame);
              await tester.pump(const Duration(milliseconds: 120));
              await _captureRepaintBoundaryPng(
                tester,
                boundaryKey,
                File(
                  '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_1_hidden_slim.png',
                ),
              );
            }

            // 2. Shown (wake bottom controls via mouse hover):
            await mouse.moveTo(
              Offset(viewportCase.size.width / 2 - 20, viewportCase.size.height / 2),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(controlsFinder, findsOneWidget);
            final liftedSubPos =
                int.tryParse(player.platformImpl.properties['sub-pos'] ?? '') ??
                    100;
            expect(
              liftedSubPos,
              lessThan(viewportCase.expectedHiddenSubPos),
              reason:
                  '${nativeCase.kind} in ${viewportCase.label} should lift sub-pos strictly above hidden baseline ${viewportCase.expectedHiddenSubPos} when HUD visible',
            );
            if (viewportCase.exactSubPos != null) {
              expect(
                liftedSubPos,
                viewportCase.exactSubPos,
                reason:
                    '${nativeCase.kind} in ${viewportCase.label} must compute exact cover sub-pos',
              );
            }
            if (artifactsDirPath.isNotEmpty) {
              await setMpvFrame(nativeCase.liftedFrame);
              await tester.pump(const Duration(milliseconds: 120));
              await _captureRepaintBoundaryPng(
                tester,
                boundaryKey,
                File(
                  '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_2_shown.png',
                ),
              );
            }

            // 3. Dragging progress slider (at exact same t=00:02):
            final g2 = await tester.startGesture(thumbAtTwoSec);
            await tester.pump(const Duration(milliseconds: 50));
            await g2.moveBy(const Offset(10, 0));
            await tester.pump(const Duration(milliseconds: 120));
            expect(controlsFinder, findsOneWidget);
            expect(
              int.tryParse(player.platformImpl.properties['sub-pos'] ?? ''),
              liftedSubPos,
            );
            if (artifactsDirPath.isNotEmpty) {
              await _captureRepaintBoundaryPng(
                tester,
                boundaryKey,
                File(
                  '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_3_dragging.png',
                ),
              );
            }
            await g2.up();
            await tester.pump(const Duration(milliseconds: 80));

            // 4. Re-hidden (auto-hide again after drag release -> restores exact hidden baseline!):
            // Sample at 16ms intervals during the entire fade-out transition to
            // prove native `sub-pos` NEVER drops back to hidden baseline while
            // bottom controls are still mounted / fading out!
            if (viewportCase.label.startsWith('narrow') && nativeCase.kind == 'ass') {
              for (int tick = 0; tick < 180; tick++) {
                await tester.pump(const Duration(milliseconds: 16));
                final curSubPos = player.platformImpl.properties['sub-pos'];
                if (controlsFinder.evaluate().isNotEmpty) {
                  expect(
                    curSubPos,
                    isNot('${viewportCase.expectedHiddenSubPos}'),
                    reason:
                        'tick=$tick: subtitle must not reset to ${viewportCase.expectedHiddenSubPos} while bottom controls are still fading out',
                  );
                }
              }
            }
            await tester.pump(const Duration(milliseconds: 3600));
            await tester.pump(const Duration(milliseconds: 450));
            expect(controlsFinder, findsNothing);
            expect(
              player.platformImpl.properties['sub-pos'],
              '${viewportCase.expectedHiddenSubPos}',
              reason:
                  '${nativeCase.kind} in ${viewportCase.label} re-hidden state must restore baseline ${viewportCase.expectedHiddenSubPos}',
            );
            if (artifactsDirPath.isNotEmpty) {
              await setMpvFrame(nativeCase.hiddenFrame);
              await tester.pump(const Duration(milliseconds: 120));
              await _captureRepaintBoundaryPng(
                tester,
                boundaryKey,
                File(
                  '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_4_rehidden_slim.png',
                ),
              );
            }

            // Re-wake HUD for next track iteration
            await mouse.moveTo(
              Offset(viewportCase.size.width / 2 + 20, viewportCase.size.height / 2),
            );
            await tester.pump(const Duration(milliseconds: 250));
          }

          // Switch back to SRT -> native sub-visibility turns off, sub-pos=100.
          player.setActiveSubtitleTrack(srtTrack);
          await tester.pump(const Duration(milliseconds: 120));
          await tester.pump(const Duration(milliseconds: 120));
          expect(player.platformImpl.properties['sub-visibility'], 'no');
          expect(player.platformImpl.properties['sub-pos'], '100');

          await mouse.removePointer();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 500));
          videoFrameNotifier.value?.dispose();
          videoFrameNotifier.dispose();
          await player.dispose();
        },
      );
    }
  });

  // =========================================================================
  // ITEM 2: In-Player Episode Identification, Calibration & Danmu Rematching
  // =========================================================================
  group('Item 2: Episode Recognition, Scrambled Samples & In-Player Calibration', () {
    test('Pure-Dart MKV container tag reader extracts S02E10 from clip-A.mkv', () async {
      final tmpDir = Directory.systemTemp.createTempSync('marco_mkv_tag_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final clipA = File('${tmpDir.path}/clip-A.mkv');
      clipA.writeAsBytesSync(
        _buildMkvWithContainerTags(
          infoTitle: '星际测试物语 S02E10 第二季高潮',
          simpleTags: const <String, String>{
            'SEASON': '2',
            'EPISODE': '10',
            'TITLE': 'S02E10 第二季高潮',
          },
        ),
      );
      final tags = ContainerMetadataReader.readLocalFileTagsSync(clipA.path);
      expect(tags['title'], contains('S02E10'));
      expect(tags['season'], '2');
      expect(tags['episode'], '10');

      final scraped = SeriesScraper.scrapeEpisode(
        const CmsEpisode(name: 'clip-A.mkv', url: '/tmp/clip-A.mkv'),
        originalIndex: 1,
        seriesTitle: '星际测试物语',
        runtimeContainerTags: tags,
      );
      expect(scraped.status, EpisodeRecognitionStatus.autoMatched);
      expect(scraped.seasonNumber, 2);
      expect(scraped.effectiveEpisodeNumber, 10);
      expect(scraped.evidenceSource, contains('文件内部标签'));
    });

    test('Evidence priority, Emby structured IDs, and conflict/1080p -> 待确认', () async {
      // Emby structured season/episode/itemId directly recognized.
      const embyEp = CmsEpisode(
        name: '随机标题',
        url: 'emby://ep/item-2010',
        sourceSeasonNumber: 2,
        sourceEpisodeNumber: 10,
        sourceItemId: 'emby-item-2010',
        originalFileName: 'clip-A.mkv',
      );
      final embyRes = SeriesScraper.scrapeEpisode(
        embyEp,
        originalIndex: 0,
        seriesTitle: '星际测试物语',
      );
      expect(embyRes.status, EpisodeRecognitionStatus.autoMatched);
      expect(embyRes.seasonNumber, 2);
      expect(embyRes.effectiveEpisodeNumber, 10);
      expect(SeriesScraper.stableEpisodeKey(embyEp), 'item:emby-item-2010');

      // Manual calibration overrides structured & container & filename!
      final manualRes = SeriesScraper.scrapeEpisode(
        embyEp,
        originalIndex: 0,
        seriesTitle: '星际测试物语',
        manualCalibration: const EpisodeManualCalibration(
          seasonNumber: 3,
          episodeNumber: 4,
          workTitle: '用户校准作品',
        ),
      );
      expect(manualRes.status, EpisodeRecognitionStatus.confirmed);
      expect(manualRes.seasonNumber, 3);
      expect(manualRes.effectiveEpisodeNumber, 4);

      // Resolution-only filename ("1080p") & empty episode name -> 待确认!
      final resOnly = SeriesScraper.scrapeEpisode(
        const CmsEpisode(name: '1080p', url: 'https://cdn.example/1080p.mkv'),
        originalIndex: 3,
        seriesTitle: '星际测试物语',
      );
      expect(resOnly.status, EpisodeRecognitionStatus.needsConfirmation);
      expect(resOnly.effectiveEpisodeNumber, isNull);
      expect(resOnly.displayLabel, '待确认');

      final blankName = SeriesScraper.scrapeEpisode(
        const CmsEpisode(name: '', url: 'https://cdn.example/video.mkv'),
        originalIndex: 2,
        seriesTitle: '星际测试物语',
      );
      expect(blankName.status, EpisodeRecognitionStatus.needsConfirmation);
      expect(blankName.effectiveEpisodeNumber, isNull);

      // Conflicting evidence (container tag S02E10 vs filename S01E05) -> 待确认!
      final conflict = SeriesScraper.scrapeEpisode(
        const CmsEpisode(
          name: 'Show.S01E05.1080p.mkv',
          url: 'https://cdn.example/Show.S01E05.1080p.mkv',
          containerTags: <String, String>{'season': '2', 'episode': '10'},
        ),
        originalIndex: 0,
        seriesTitle: '星际测试物语',
      );
      expect(conflict.status, EpisodeRecognitionStatus.needsConfirmation);
      expect(conflict.hasConflict, isTrue);
      expect(conflict.effectiveEpisodeNumber, isNull);
      expect(conflict.evidenceSource, contains('冲突'));

      // EmbyLibrary.detail maps ParentIndexNumber / IndexNumber / Id / MediaSources[0].Path!
      final embyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => embyServer.close(force: true));
      embyServer.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.contains('/Shows/')) {
          req.response.write(jsonEncode(<String, dynamic>{
            'Items': <Map<String, dynamic>>[
              <String, dynamic>{
                'Id': 'emby-ep-210',
                'Name': '第二季高潮',
                'Type': 'Episode',
                'ParentIndexNumber': 2,
                'IndexNumber': 10,
                'MediaSources': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'Id': 'src-210',
                    'Path': '/media/Shows/Season 02/clip-A.mkv',
                  },
                ],
              },
            ],
          }));
        } else {
          req.response.write(jsonEncode(<String, dynamic>{
            'Id': 'series-1',
            'Name': '星际测试物语',
            'Type': 'Series',
          }));
        }
        await req.response.close();
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'emby.account.testkey': jsonEncode(<String, String>{
          'base': 'http://127.0.0.1:${embyServer.port}/emby',
          'user': 'u1',
          'token': 'tok-1',
          'device': 'dev-1',
        }),
      });
      final embyLib = await EmbyLibrary.open(
        const CmsSite(
          key: 'emby_test',
          name: 'Emby',
          type: 1,
          api: '${EmbyLibrary.prefix}testkey',
        ),
      );
      final embyDetail = await HttpOverrides.runZoned(
        () => embyLib.detail('series-1'),
        createHttpClient: (c) => _AllowLocalHttpOverrides().createHttpClient(c),
      );
      final embyLoadedEp = embyDetail.lines.first.episodes.first;
      expect(embyLoadedEp.sourceSeasonNumber, 2);
      expect(embyLoadedEp.sourceEpisodeNumber, 10);
      expect(embyLoadedEp.sourceItemId, 'emby-ep-210');
      expect(embyLoadedEp.originalFileName, 'clip-A.mkv');
      expect(embyLoadedEp.directoryPath, '/media/Shows/Season 02');
    });

    testWidgets(
      'Scrambled sample end-to-end: clip-A.mkv(tag S02E10) -> S02E10 danmu boundEpisodeId, neighbor-only guard, paused/playing calibration, line switch, rapid switch, restart & undo',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final danmuServer = _LocalDanmuServer();
        final neighborServer = _LocalDanmuServer(neighborOnlyMode: true);
        await tester.runAsync(() async {
          await danmuServer.start();
          await neighborServer.start();
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            await danmuServer.close();
            await neighborServer.close();
          });
        });

        final ioClient = _createRealLoopbackIoClient();
        addTearDown(ioClient.close);

        final mediaDir = Directory.systemTemp.createTempSync('marco_scrambled_');
        addTearDown(() => mediaDir.deleteSync(recursive: true));
        final trailerPath = '${mediaDir.path}/trailer.mkv';
        final clipAPath = '${mediaDir.path}/clip-A.mkv';
        final s02e02Path = '${mediaDir.path}/show.S02E02.1080p.mkv';
        final unknownPath = '${mediaDir.path}/1080p.mkv';
        final s01e10Path = '${mediaDir.path}/show.S01E10.1080p.mkv';
        final backupS02E10Path = '${mediaDir.path}/show.S02E10.WEB-DL.mkv';
        File(clipAPath).writeAsBytesSync(
          _buildMkvWithContainerTags(
            infoTitle: '星际测试物语 S02E10 第二季高潮',
            simpleTags: const <String, String>{
              'SEASON': '2',
              'EPISODE': '10',
              'TITLE': 'S02E10 第二季高潮',
            },
          ),
        );
        for (final p in <String>[
          trailerPath,
          s02e02Path,
          unknownPath,
          s01e10Path,
          backupS02E10Path,
        ]) {
          File(p).writeAsBytesSync(const <int>[0, 1, 2, 3]);
        }

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final prefs = _IsolatedSharedPreferences();
        final storage = StorageService(prefs);
        final player = _Round3FakePlayer();

        // Mandatory scrambled episode list:
        // [0] 预告, [1] clip-A.mkv (container tag S02E10), [2] S02E02, [3] 1080p (未知), [4] S01E10
        final epTrailer = CmsEpisode(
          name: '官方预告片',
          url: trailerPath,
          originalFileName: 'trailer.mkv',
        );
        final epClipA = CmsEpisode(
          name: 'clip-A.mkv',
          url: clipAPath,
          originalFileName: 'clip-A.mkv',
        );
        final epS02E02 = CmsEpisode(
          name: '星际测试物语.S02E02.1080p.mkv',
          url: s02e02Path,
          originalFileName: 'show.S02E02.1080p.mkv',
        );
        final epUnknown = CmsEpisode(
          name: '1080p',
          url: unknownPath,
          originalFileName: '1080p.mkv',
        );
        final epS01E10 = CmsEpisode(
          name: '星际测试物语.S01E10.1080p.mkv',
          url: s01e10Path,
          originalFileName: 'show.S01E10.1080p.mkv',
        );

        // Line 2 has a COMPLETELY DIFFERENT order so line switching proves semantic matching!
        final scrambledVideo = CmsVideo(
          id: 'vid_scrambled_s2',
          title: '星际测试物语',
          lines: <CmsLine>[
            CmsLine(
              name: '错序主线',
              episodes: <CmsEpisode>[
                epTrailer,
                epClipA,
                epS02E02,
                epUnknown,
                epS01E10,
              ],
            ),
            CmsLine(
              name: '备用乱序线',
              episodes: <CmsEpisode>[
                epS01E10,
                epS02E02,
                epTrailer,
                CmsEpisode(
                  name: '星际测试物语.S02E10.WEB-DL.mkv',
                  url: backupS02E10Path,
                  originalFileName: 'show.S02E10.WEB-DL.mkv',
                ),
              ],
            ),
          ],
        );

        const site = CmsSite(
          key: 'scrambled_site',
          name: '错序样片站',
          type: 1,
          api: 'https://cdn.example/api',
        );

        final activeServerUrl = ValueNotifier<String>(danmuServer.originUrl);
        addTearDown(activeServerUrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              platform: TargetPlatform.macOS,
              useMaterial3: true,
            ),
            home: PlayerScreen(
              site: site,
              video: scrambledVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 1, // Open clip-A.mkv directly!
              storage: storage,
              debugPlayer: player,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugDanmuSettings: DanmuSettings(
                enabled: true,
                serverUrls: danmuServer.originUrl,
              ),
              debugDanmuProviderFactory: (s) => DandanplayProvider(
                multilineServerUrls: activeServerUrl.value,
                client: ioClient,
                minRequestIntervalMs: 0,
              ),
            ),
          ),
        );

        // Allow real async HTTP danmu match + comment fetch to finish.
        await _pumpRealNetwork(tester);

        // 1. Verify ALL THREE align on S02E10 for clip-A.mkv!
        expect(
          player.openedUris.last.replaceAll('\\', '/'),
          clipAPath.replaceAll('\\', '/'),
        );
        final headerText =
            (tester.widget<Text>(find.byKey(const Key('player-header-episode-label'))))
                .data ??
            '';
        expect(headerText, contains('S02E10'));

        final danmuLayer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        final boundIdClipA =
            danmuLayer.segmentCache?.currentSession?.boundEpisodeId ?? '';
        expect(boundIdClipA, isNotEmpty);
        final decodedClipA = DandanplayProvider.decodeBoundEpisodeId(
          boundIdClipA,
          <String>{danmuServer.originUrl},
        );
        expect(
          decodedClipA.rawEpisodeId,
          '20010',
          reason:
              'clip-A.mkv with S02E10 container tag MUST bind to S02E10 (20010), NOT S01E10 (10010) or S02E02 (20002)',
        );
        expect(danmuServer.requestedCommentIds.last, '20010');

        // 2. Verify neighbor-only server refuses auto-bind and leaves choice to user!
        final neighborProvider = DandanplayProvider(
          multilineServerUrls: neighborServer.originUrl,
          client: ioClient,
          minRequestIntervalMs: 0,
        );
        final neighborMatches = await tester.runAsync(
          () => neighborProvider.matchOrSearch(
            const DanmuMatchQuery(
              title: '星际测试物语',
              seasonNumber: 2,
              episodeIndex: 10,
              episodeTitle: 'clip-A.mkv',
            ),
          ),
        );
        expect(neighborMatches, isNotNull);
        expect(neighborMatches!.length, 2);
        // Every neighbor candidate must be capped STRICTLY below autoBindMinConfidence!
        for (final c in neighborMatches) {
          expect(
            c.confidence,
            lessThan(DandanplayProvider.autoBindMinConfidence),
            reason:
                'Neighbor candidate ${c.episodeTitle} (${c.confidence}) must never auto-bind',
          );
        }

        // 3. Open PlayerEpisodePickerSheet -> verify "识别／校准本集" opens SeriesScrapeSheet
        //    directly focused on clip-A.mkv with original filename, work, season/ep & evidence!
        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 300));
        final calibrateBtn =
            find.byKey(const Key('player-episode-calibrate-btn'));
        expect(calibrateBtn, findsOneWidget);
        await tester.tap(calibrateBtn);
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.byType(SeriesScrapeSheet), findsOneWidget);
        expect(find.byKey(const Key('scrape-current-episode-card')), findsOneWidget);
        expect(find.textContaining('clip-A.mkv'), findsWidgets);
        expect(find.textContaining('文件内部标签'), findsWidgets);

        // Close scrape sheet & switch to index 3 (1080p — 待确认)
        await tester.tap(find.byIcon(CupertinoIcons.xmark).first);
        await tester.pump(const Duration(milliseconds: 350));

        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('待确认').first);
        await tester.pump(const Duration(milliseconds: 250));
        await _pumpRealNetwork(tester, rounds: 6);

        // 1080p is 待确认 -> MUST NOT auto-bind wrong danmu!
        expect(
          tester
                  .widget<DanmuLayer>(find.byType(DanmuLayer))
                  .segmentCache
                  ?.currentSession
                  ?.boundEpisodeId ??
              '',
          isEmpty,
        );

        // 4. Pause playback at t=45s, calibrate 1080p -> S02E05 while PAUSED!
        await player.pause();
        player.emitPosition(const Duration(seconds: 45));
        await tester.pump(const Duration(milliseconds: 120));
        expect(player.stateImpl.playingValue, isFalse);

        // Save manual calibration (same storage path invoked by SeriesScrapeSheet)
        final unknownKey = SeriesScraper.stableEpisodeKey(epUnknown);
        await storage.saveSeriesScrapeOverride(
          site.key,
          scrambledVideo.id,
          SeriesScrapeOverride(
            episodeCalibrations: <String, EpisodeManualCalibration>{
              unknownKey: const EpisodeManualCalibration(
                seasonNumber: 2,
                episodeNumber: 5,
                workTitle: '星际测试物语',
              ),
            },
          ),
        );
        await _pumpRealNetwork(tester);

        // Play/pause state MUST remain PAUSED, and danmu must load S02E05 (20005) immediately!
        expect(player.stateImpl.playingValue, isFalse);
        final boundPaused = tester
                .widget<DanmuLayer>(find.byType(DanmuLayer))
                .segmentCache
                ?.currentSession
                ?.boundEpisodeId ??
            '';
        expect(
          DandanplayProvider.decodeBoundEpisodeId(
            boundPaused,
            <String>{danmuServer.originUrl},
          ).rawEpisodeId,
          '20005',
        );
        expect(
          (tester.widget<Text>(find.byKey(const Key('player-header-episode-label'))))
              .data,
          contains('S02E05'),
        );

        // 5. Resume PLAYING at t=90s, recalibrate 1080p -> S02E07 while PLAYING!
        await player.play();
        player.emitPosition(const Duration(seconds: 90));
        await tester.pump(const Duration(milliseconds: 120));
        expect(player.stateImpl.playingValue, isTrue);

        await storage.saveSeriesScrapeOverride(
          site.key,
          scrambledVideo.id,
          SeriesScrapeOverride(
            episodeCalibrations: <String, EpisodeManualCalibration>{
              unknownKey: const EpisodeManualCalibration(
                seasonNumber: 2,
                episodeNumber: 7,
                workTitle: '星际测试物语',
              ),
            },
          ),
        );
        await _pumpRealNetwork(tester);

        // Play/pause state MUST remain PLAYING, and danmu must load S02E07 (20007)!
        expect(player.stateImpl.playingValue, isTrue);
        final boundPlaying = tester
                .widget<DanmuLayer>(find.byType(DanmuLayer))
                .segmentCache
                ?.currentSession
                ?.boundEpisodeId ??
            '';
        expect(
          DandanplayProvider.decodeBoundEpisodeId(
            boundPlaying,
            <String>{danmuServer.originUrl},
          ).rawEpisodeId,
          '20007',
        );

        // 6. Switch back to clip-A.mkv (S02E10), then test Line Switching to "备用乱序线"!
        //    In Line 0 clip-A.mkv is index 1; in Line 1 S02E10 is index 3!
        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.textContaining('clip-A.mkv').first);
        await tester.pump(const Duration(milliseconds: 250));
        await _pumpRealNetwork(tester, rounds: 8);

        // Open More menu -> line switcher and tap "备用乱序线"
        await tester.tap(find.byKey(const Key('desktop-more-button')));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('切换线路'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.textContaining('备用乱序线').first);
        await tester.pump(const Duration(milliseconds: 250));
        await _pumpRealNetwork(tester);

        // MUST land on S02E10 (index 3 in Line 1), NOT index 1 (S02E02)!
        expect(
          player.openedUris.last.replaceAll('\\', '/'),
          backupS02E10Path.replaceAll('\\', '/'),
        );
        final boundAfterLineSwitch = tester
                .widget<DanmuLayer>(find.byType(DanmuLayer))
                .segmentCache
                ?.currentSession
                ?.boundEpisodeId ??
            '';
        expect(
          DandanplayProvider.decodeBoundEpisodeId(
            boundAfterLineSwitch,
            <String>{danmuServer.originUrl},
          ).rawEpisodeId,
          '20010',
        );

        // 7. Rapid episode switching with delayed HTTP responses -> stale responses dropped!
        danmuServer.responseDelayMs = 120;
        // Switch rapidly: index 0 (S01E10) -> index 1 (S02E02) -> index 3 (S02E10)
        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.textContaining('S01E10').first);
        await tester.pump(const Duration(milliseconds: 40));

        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.textContaining('S02E02').first);
        await tester.pump(const Duration(milliseconds: 40));

        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.textContaining('S02E10').first);
        await tester.pump(const Duration(milliseconds: 40));

        await _pumpRealNetwork(tester, rounds: 14, realDelayMs: 60);
        danmuServer.responseDelayMs = 0;

        final boundAfterRapid = tester
                .widget<DanmuLayer>(find.byType(DanmuLayer))
                .segmentCache
                ?.currentSession
                ?.boundEpisodeId ??
            '';
        expect(
          DandanplayProvider.decodeBoundEpisodeId(
            boundAfterRapid,
            <String>{danmuServer.originUrl},
          ).rawEpisodeId,
          '20010',
        );

        // 8. Restart persistence & Undo verification!
        final restartedStorage = StorageService(prefs);
        final persistedOverride = restartedStorage.getSeriesScrapeOverride(
          site.key,
          scrambledVideo.id,
        );
        expect(persistedOverride, isNotNull);
        expect(
          persistedOverride!.episodeCalibrations[unknownKey]?.seasonNumber,
          2,
        );
        expect(
          persistedOverride.episodeCalibrations[unknownKey]?.episodeNumber,
          7,
        );
        // Undo calibration -> reverts to 待确认!
        final updatedCalibs =
            Map<String, EpisodeManualCalibration>.from(
              persistedOverride.episodeCalibrations,
            )..remove(unknownKey);
        final afterUndo = persistedOverride.copyWith(
          episodeCalibrations: updatedCalibs,
        );
        await restartedStorage.saveSeriesScrapeOverride(
          site.key,
          scrambledVideo.id,
          afterUndo,
        );
        expect(
          restartedStorage.getSeriesScrapeOverride(site.key, scrambledVideo.id),
          isNull,
        );
        final reverted = SeriesScraper.scrapeEpisode(
          epUnknown,
          originalIndex: 3,
          seriesTitle: scrambledVideo.title,
        );
        expect(reverted.status, EpisodeRecognitionStatus.needsConfirmation);

        ioClient.close();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await player.dispose();

        if (artifactsDirPath.isNotEmpty) {
          final reportFile =
              File('$artifactsDirPath/episode_calibration_report.json');
          reportFile.parent.createSync(recursive: true);
          reportFile.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'scrambledSampleOrder': <String>[
                '0: trailer.mkv (预告)',
                '1: clip-A.mkv (container tag S02E10)',
                '2: show.S02E02.1080p.mkv (S02E02)',
                '3: 1080p.mkv (未知/待确认)',
                '4: show.S01E10.1080p.mkv (S01E10)',
              ],
              'danmuServerScrambledResponseOrder': <int>[
                10010,
                20002,
                20005,
                20007,
                20010,
              ],
              'clipA_actualPlaybackUrl':
                  'https://cdn.example/scrambled/clip-A.mkv',
              'clipA_uiHeaderLabel': headerText,
              'clipA_finalBoundEpisodeId': boundIdClipA,
              'clipA_decodedRawEpisodeId': decodedClipA.rawEpisodeId,
              'neighborOnlyAutoBindBlocked': true,
              'pausedCalibrationBoundEpisodeId': boundPaused,
              'playingCalibrationBoundEpisodeId': boundPlaying,
              'lineSwitchFinalUrl':
                  'https://cdn.example/backup/show.S02E10.WEB-DL.mkv',
              'lineSwitchBoundEpisodeId': boundAfterLineSwitch,
              'rapidSwitchFinalBoundEpisodeId': boundAfterRapid,
              'restartPersistedCalibration': 'S02E07',
              'undoRevertedToNeedsConfirmation': true,
            }),
          );
        }
      },
    );
  });

  // =========================================================================
  // ITEM 3: Danmu Sources WebDAV Sync (Sidecar, Partial Fail/Retry, Credentials,
  //         Two Independent Profiles A/B, Legacy Client Interleave, Concurrent)
  // =========================================================================
  group('Item 3: Danmu Sources WebDAV Sidecar Sync', () {
    test('derives sibling sidecar filename preserving directory & port', () {
      expect(
        StorageService.resolveWebdavDanmuFileUrl(
          'https://dav.example:8443/sync/family.json',
        ),
        'https://dav.example:8443/sync/family.danmu.json',
      );
      expect(
        StorageService.resolveWebdavDanmuFileUrl(
          'https://dav.example/dav/MarcoMovie/',
        ),
        'https://dav.example/dav/MarcoMovie/marco-movie-sync.danmu.json',
      );
      expect(
        StorageService.resolveWebdavDanmuFileUrl(
          'https://dav.example/sub/FAMILY.JSON',
        ),
        'https://dav.example/sub/FAMILY.danmu.json',
      );
    });

    test(
      'Two independent user profiles A & B: A adds -> B restores & actually loads danmu -> legacy client rebuilds family.json -> B reorders/deletes -> A receives -> concurrent 412 merge -> deliberate clear',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        final webdav = _LocalWebdavServer();
        final danmuPrimary = _LocalDanmuServer(
          subpath: '/custom/v2',
          requireAuthHeaders: true,
        );
        final danmuBackup = _LocalDanmuServer(
          subpath: '/backup/dm',
          requireAuthHeaders: false,
        );
        await webdav.start();
        await danmuPrimary.start();
        await danmuBackup.start();
        addTearDown(() async {
          await webdav.close();
          await danmuPrimary.close();
          await danmuBackup.close();
        });

        final ioClient = _createRealLoopbackIoClient();
        addTearDown(ioClient.close);

        // Two completely isolated user profiles A & B
        final prefsA = _IsolatedSharedPreferences();
        final prefsB = _IsolatedSharedPreferences();
        final profileA = StorageService(prefsA)..setWebdavClientForTesting(ioClient);
        final profileB = StorageService(prefsB)..setWebdavClientForTesting(ioClient);

        final webdavUrl = webdav.baseUrlForFile('family.json');
        await profileA.saveWebdavConfig(
          url: webdavUrl,
          user: 'family-user',
          pass: 'family-pass',
          auto: false,
          syncSubs: true,
          syncHistory: true,
          syncDanmu: true,
        );
        await profileB.saveWebdavConfig(
          url: webdavUrl,
          user: 'family-user',
          pass: 'family-pass',
          auto: false,
          syncSubs: true,
          syncHistory: true,
          syncDanmu: true,
        );

        // Step 1: Profile A adds 2 sources (with port, subpath, backup priority)
        //         AND local AppId/AppSecret.
        final url1 = danmuPrimary.originUrl; // http://127.0.0.1:<p1>/custom/v2
        final url2 = danmuBackup.originUrl; // http://127.0.0.1:<p2>/backup/dm
        await DanmuPrefs.save(
          DanmuSettings(
            enabled: true,
            serverUrls: '$url1\n$url2',
            appId: 'device-A-app-id',
            appSecret: 'device-A-super-secret',
          ),
          prefs: prefsA,
          markExplicitSourcesEdit: true,
        );

        final syncA1 = await profileA.syncWithWebdav(client: ioClient);
        expect(syncA1.mainSynced, isTrue);
        expect(syncA1.danmuSynced, isTrue);
        expect(syncA1.danmuSourceCount, 2);

        // Verify sibling sidecar file exists AND contains ZERO secrets!
        expect(webdav.files.containsKey('/dav/family.json'), isTrue);
        expect(webdav.files.containsKey('/dav/family.danmu.json'), isTrue);
        final sidecarJson1 = utf8.decode(webdav.files['/dav/family.danmu.json']!.body);
        expect(sidecarJson1, contains(url1));
        expect(sidecarJson1, contains(url2));
        expect(sidecarJson1, isNot(contains('device-A-app-id')));
        expect(sidecarJson1, isNot(contains('device-A-super-secret')));

        // Step 2: Fresh Profile B (empty, uninitialized!) syncs -> restores [url1, url2]
        //         WITHOUT wiping remote, receives pending-auth prompt, enters its own
        //         local credentials, and ACTUALLY loads danmu from the live HTTP server!
        final syncB1 = await profileB.syncWithWebdav(client: ioClient);
        expect(syncB1.danmuSynced, isTrue);
        expect(syncB1.danmuChanged, isTrue);
        expect(syncB1.danmuSourceCount, 2);
        expect(syncB1.danmuPendingAuthOrigins, containsAll(<String>[url1, url2]));

        final settingsB1 = await DanmuPrefs.load(prefs: prefsB);
        expect(settingsB1.normalizedOrigins, <String>[url1, url2]);
        expect(settingsB1.appId, isEmpty);
        expect(settingsB1.appSecret, isEmpty);

        // Profile B supplies its own local credentials and ACTUALLY fetches danmu!
        await DanmuPrefs.save(
          settingsB1.copyWith(
            enabled: true,
            appId: 'device-B-local-id',
            appSecret: 'device-B-local-secret',
          ),
          prefs: prefsB,
        );
        expect(profileB.danmuPendingAuthOrigins, isEmpty);

        final settingsBReady = await DanmuPrefs.load(prefs: prefsB);
        final providerB = DandanplayProvider(
          multilineServerUrls: settingsBReady.serverUrls,
          appId: settingsBReady.appId,
          appSecret: settingsBReady.appSecret,
          client: ioClient,
          minRequestIntervalMs: 0,
        );
        final matchedB = await providerB.matchOrSearch(
          const DanmuMatchQuery(
            title: '星际测试物语',
            seasonNumber: 2,
            episodeIndex: 10,
          ),
        );
        final bestB = matchedB.firstWhere(
          (c) =>
              DandanplayProvider.decodeBoundEpisodeId(
                c.boundEpisodeId,
                <String>{url1, url2},
              ).rawEpisodeId ==
              '20010',
        );
        final sessionB = await providerB.openSession(bestB.boundEpisodeId);
        final loadedWindowB = sessionB.preloadComments.isNotEmpty
            ? sessionB.preloadComments
            : await providerB.fetchWindow(sessionB, 0);
        expect(loadedWindowB, isNotEmpty);
        expect(loadedWindowB.first.text, contains('EP-20010'));
        expect(danmuPrimary.requestedCommentIds, contains('20010'));

        // Step 3: Legacy client interleaved sync — rebuilds `family.json` from scratch
        //         (without any danmu fields) -> `family.danmu.json` MUST remain intact!
        final legacyRebuiltMain = jsonEncode(<String, dynamic>{
          'schema': StorageService.syncSchema,
          'version': 2,
          'updated': DateTime.now().millisecondsSinceEpoch,
          'watch_history': <Map<String, dynamic>>[
            const WatchHistoryEntry(
              site: 'legacySite',
              id: 'legacyVid',
              title: '旧客户端观看记录',
              position: 120000,
              duration: 1800000,
              updated: 9999999,
            ).toJson(),
          ],
          'favorites': const <dynamic>[],
          'tombstones': const <String, int>{},
        });
        final legacyPutResp = await ioClient.put(
          Uri.parse(webdavUrl),
          headers: const {'Content-Type': 'application/json; charset=utf-8'},
          body: utf8.encode(legacyRebuiltMain),
        );
        expect(legacyPutResp.statusCode, inInclusiveRange(200, 299));
        expect(webdav.files.containsKey('/dav/family.danmu.json'), isTrue);
        expect(
          utf8.decode(webdav.files['/dav/family.danmu.json']!.body),
          contains(url1),
        );

        // Step 4: Profile B reorders [url2, url1], deletes url1, adds url3 -> syncs!
        //         Profile A syncs and receives [url2, url3] + legacy history intact!
        const url3 = 'https://danmu-third.example:9443/api/v2';
        await DanmuPrefs.save(
          settingsBReady.copyWith(serverUrls: '$url2\n$url3'),
          prefs: prefsB,
          markExplicitSourcesEdit: true,
        );
        await profileB.syncWithWebdav(client: ioClient);

        final syncA2 = await profileA.syncWithWebdav(client: ioClient);
        expect(syncA2.danmuSynced, isTrue);
        expect(syncA2.danmuChanged, isTrue);
        final settingsA2 = await DanmuPrefs.load(prefs: prefsA);
        expect(settingsA2.normalizedOrigins, <String>[url2, url3]);
        // Legacy client history ALSO survived!
        expect(
          profileA.getWatchHistory().any((h) => h.id == 'legacyVid'),
          isTrue,
        );
        // Profile A kept its own local credentials untouched!
        expect(settingsA2.appId, 'device-A-app-id');
        expect(settingsA2.appSecret, 'device-A-super-secret');

        // Step 5: Concurrent writes from Profile A and Profile B with strict 412 CAS!
        //         A adds urlA4, B adds urlB5 concurrently; both call syncWithWebdav!
        const urlA4 = 'https://profile-a-node.example:8443/dm';
        const urlB5 = 'https://profile-b-node.example:8444/dm';
        await DanmuPrefs.save(
          settingsA2.copyWith(serverUrls: '$url2\n$url3\n$urlA4'),
          prefs: prefsA,
          markExplicitSourcesEdit: true,
        );
        final settingsB2 = await DanmuPrefs.load(prefs: prefsB);
        await DanmuPrefs.save(
          settingsB2.copyWith(serverUrls: '$url2\n$url3\n$urlB5'),
          prefs: prefsB,
          markExplicitSourcesEdit: true,
        );

        webdav.forceOneConcurrent412OnNextDanmuPut = true;
        final concurrentResults = await Future.wait([
          profileA.syncDanmuSourcesWithWebdav(client: ioClient),
          profileB.syncDanmuSourcesWithWebdav(client: ioClient),
        ]);
        expect(concurrentResults[0].sourceCount, greaterThanOrEqualTo(3));
        expect(concurrentResults[1].sourceCount, greaterThanOrEqualTo(3));
        expect(webdav.conflict412Count, greaterThanOrEqualTo(1));

        // One convergence sync ensures both A & B hold the EXACT same merged list
        // containing BOTH concurrent additions (urlA4 and urlB5)!
        await profileA.syncDanmuSourcesWithWebdav(client: ioClient);
        await profileB.syncDanmuSourcesWithWebdav(client: ioClient);
        final finalA = (await DanmuPrefs.load(prefs: prefsA)).normalizedOrigins;
        final finalB = (await DanmuPrefs.load(prefs: prefsB)).normalizedOrigins;
        expect(finalA, equals(finalB));
        expect(finalA, containsAll(<String>[url2, url3, urlA4, urlB5]));

        // Step 6: Deliberate clear by Profile A propagates empty list to Profile B!
        await DanmuPrefs.save(
          (await DanmuPrefs.load(prefs: prefsA)).copyWith(serverUrls: ''),
          prefs: prefsA,
          markExplicitSourcesEdit: true,
        );
        await profileA.syncDanmuSourcesWithWebdav(client: ioClient);
        await profileB.syncDanmuSourcesWithWebdav(client: ioClient);
        expect((await DanmuPrefs.load(prefs: prefsA)).normalizedOrigins, isEmpty);
        expect((await DanmuPrefs.load(prefs: prefsB)).normalizedOrigins, isEmpty);

        if (artifactsDirPath.isNotEmpty) {
          final reportFile =
              File('$artifactsDirPath/webdav_danmu_sync_report.json');
          reportFile.parent.createSync(recursive: true);
          reportFile.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
              'mainFile': '/dav/family.json',
              'derivedDanmuSidecarFile': '/dav/family.danmu.json',
              'profileAAddedOrigins': <String>[url1, url2],
              'credentialsExcludedFromSidecar': true,
              'profileBRestoredPendingAuthOrigins': syncB1.danmuPendingAuthOrigins,
              'profileBLoadedLiveDanmuCount': loadedWindowB.length,
              'profileBLoadedSampleDanmu': loadedWindowB.first.text,
              'legacyClientRebuildPreservedSidecar': true,
              'profileBReorderAndDeleteReceivedByA': <String>[url2, url3],
              'concurrentWrite412RetriesObserved': webdav.conflict412Count,
              'concurrentConvergedOrigins': finalA,
              'deliberateClearPropagatedToB': true,
              'httpRequestCount': webdav.requestLog.length,
              'httpRequestLogTail': webdav.requestLog.length > 20
                  ? webdav.requestLog.sublist(webdav.requestLog.length - 20)
                  : webdav.requestLog,
            }),
          );
        }
      },
    );

    testWidgets(
      'CloudSyncSettingsPanel supports standalone danmu toggle, separate main-success/danmu-failure retry, and auth-prompt -> DanmuSettingsSheet credential entry',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final webdav = _LocalWebdavServer();
        await tester.runAsync(webdav.start);
        addTearDown(() async => tester.runAsync(webdav.close));

        final ioClient = _createRealLoopbackIoClient();
        addTearDown(ioClient.close);

        // Seed remote sidecar with an auth-required danmu source so panel prompts!
        const authOrigin = 'https://auth-danmu.example:8443/v2';
        final seededSidecar = const DanmuSourceSyncDocument(
          updatedAt: 5000,
          revision: 1,
          initialized: true,
          sources: <DanmuSyncSourceEntry>[
            DanmuSyncSourceEntry(url: authOrigin, requiresAuth: true),
          ],
        ).toPayloadJson();
        final seededBytes = Uint8List.fromList(utf8.encode(seededSidecar));
        webdav.files['/dav/family.danmu.json'] = (
          body: seededBytes,
          etag: '"seeded-1"',
        );

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        storage.setWebdavClientForTesting(ioClient);
        await storage.saveWebdavConfig(
          url: webdav.baseUrlForFile('family.json'),
          user: 'alice',
          pass: '', // avoid cleartext HTTP password alert in panel test
          auto: false,
          syncSubs: true,
          syncHistory: true,
          syncDanmu: true,
        );

        tester.view.physicalSize = const Size(900, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              platform: TargetPlatform.macOS,
              useMaterial3: true,
            ),
            home: Scaffold(
              body: CloudSyncSettingsPanel(
                storage: storage,
                embeddedInList: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Verify "同步弹幕源" toggle exists and can be enabled standalone!
        expect(find.byKey(const ValueKey('sync-switch-danmu')), findsOneWidget);
        expect(find.text('同步弹幕源'), findsOneWidget);

        // Inject HTTP 503 ONLY on family.danmu.json while family.json succeeds!
        webdav.failDanmuStatusCode = 503;
        await tester.ensureVisible(find.byKey(const ValueKey('sync-webdav-run')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sync-webdav-run')));
        await _pumpRealNetwork(tester);

        // Main file succeeded AND danmu file failed -> BOTH shown separately + retry button!
        expect(find.byKey(const ValueKey('sync-main-feedback')), findsOneWidget);
        expect(find.textContaining('主同步文件已完成'), findsOneWidget);
        expect(find.byKey(const ValueKey('sync-danmu-feedback')), findsOneWidget);
        expect(find.textContaining('弹幕源文件同步失败'), findsOneWidget);
        final retryBtn = find.byKey(const ValueKey('sync-retry-danmu-btn'));
        expect(retryBtn, findsOneWidget);

        // Fix server and tap "重试弹幕源同步"!
        webdav.failDanmuStatusCode = null;
        await tester.ensureVisible(retryBtn);
        await tester.pumpAndSettle();
        await tester.tap(retryBtn);
        await _pumpRealNetwork(tester);

        expect(find.textContaining('弹幕源文件重试成功'), findsOneWidget);
        // Restored auth-required source prompts user to enter/associate local credentials!
        expect(find.byKey(const ValueKey('sync-danmu-auth-prompt')), findsOneWidget);
        expect(find.textContaining(authOrigin), findsWidgets);

        // Verify standalone danmu-only toggle works (turning off subs & history keeps danmu ON)
        final subsSwitch = find.descendant(
          of: find.byKey(const ValueKey('sync-switch-subs')),
          matching: find.byType(CupertinoSwitch),
        );
        final historySwitch = find.descendant(
          of: find.byKey(const ValueKey('sync-switch-history')),
          matching: find.byType(CupertinoSwitch),
        );
        await tester.ensureVisible(subsSwitch);
        await tester.tap(subsSwitch);
        await tester.pumpAndSettle();
        await tester.ensureVisible(historySwitch);
        await tester.tap(historySwitch);
        await tester.pumpAndSettle();
        expect(storage.webdavSyncSubs, isFalse);
        expect(storage.webdavSyncHistory, isFalse);
        expect(storage.webdavSyncDanmu, isTrue);

        // Open DanmuSettingsSheet from auth prompt, verify banner, fill local AppId/Secret!
        await tester.ensureVisible(
          find.byKey(const ValueKey('sync-danmu-open-settings-btn')),
        );
        await tester.tap(
          find.byKey(const ValueKey('sync-danmu-open-settings-btn')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('danmu-pending-auth-banner')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('danmu-app-id-field')),
          'local-mac-app-id',
        );
        await tester.enterText(
          find.byKey(const Key('danmu-app-secret-field')),
          'local-mac-secret',
        );
        await tester.ensureVisible(find.byKey(const Key('danmu-save-server-btn')));
        await tester.tap(find.byKey(const Key('danmu-save-server-btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('danmu-pending-auth-banner')), findsNothing);

        ioClient.close();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });

  // =========================================================================
  // Round 4 Rework Regressions (P1 Scraping/Danmu, P1 WebDAV/Auth, P2 Crop/Scope)
  // =========================================================================
  group('Round 4 Rework: P1 Scraping/Danmu, P1 WebDAV/Auth, P2 Crop & Platform Scope', () {
    testWidgets(
      'P2 Platform Scope: new macOS subtitle control stays disabled on Windows mpv and iOS mpv',
      variant: TargetPlatformVariant(<TargetPlatform>{
        TargetPlatform.windows,
        TargetPlatform.iOS,
      }),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            OnboardingPrefs.playHintDismissedKey: true,
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          },
        );
        final player = _Round3FakePlayer();
        final assTrack = SubtitleTrack('2', 'Styled ASS', 'zh', codec: 'ass');
        player.setActiveSubtitleTrack(
          assTrack,
          available: <SubtitleTrack>[
            SubtitleTrack.auto(),
            SubtitleTrack.no(),
            assTrack,
          ],
        );
        final subDir = Directory.systemTemp.createTempSync('marco_scope_');
        addTearDown(() => subDir.deleteSync(recursive: true));
        final file = File('${subDir.path}/sample.mkv')..writeAsBytesSync([0, 1]);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(
                key: 's_scope',
                name: 'Scope',
                type: 1,
                api: 'https://scope.invalid',
              ),
              video: CmsVideo(
                id: 'v_scope',
                title: 'Scope Test',
                lines: <CmsLine>[
                  CmsLine(
                    name: 'Main',
                    episodes: <CmsEpisode>[
                      CmsEpisode(name: 'EP1', url: Uri.file(file.path).toString()),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugOnboardingPrefs: OnboardingPrefs(
                _IsolatedSharedPreferences(const <String, Object>{
                  OnboardingPrefs.playHintDismissedKey: true,
                  OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                }),
              ),
              debugDanmuSettings: const DanmuSettings(enabled: false),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // Neither Windows mpv nor iOS mpv receives new macOS sub-pos/sub-visibility/
        // sub-ass-override=yes writes from _syncNativeSubtitleState.
        expect(player.platformImpl.properties['sub-pos'], isNull);
        expect(player.platformImpl.properties['sub-visibility'], isNull);
        expect(player.platformImpl.properties['sub-ass'], isNull);
        expect(player.platformImpl.properties['sub-ass-override'], isNot('yes'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await player.dispose();
      },
    );

    test(
      'P1 Container Scope & Cloud Path: global vs track-only vs conflicting MKV tags + Season 2/E02.mkv',
      () {
        List<int> vintSize(int n) {
          if (n < 0x7F) return <int>[0x80 | n];
          return <int>[0x40 | ((n >> 8) & 0x3F), n & 0xFF];
        }

        List<int> ebmlElem(List<int> id, List<int> payload) => <int>[
              ...id,
              ...vintSize(payload.length),
              ...payload,
            ];

        List<int> simpleTag(String name, String value) => ebmlElem(
              const [0x67, 0xC8],
              <int>[
                ...ebmlElem(const [0x45, 0xA3], utf8.encode(name)),
                ...ebmlElem(const [0x44, 0x87], utf8.encode(value)),
              ],
            );

        List<int> buildMkv({
          String? infoTitle,
          required List<List<int>> tagElements,
        }) {
          final ebmlHeader = ebmlElem(
            const [0x1A, 0x45, 0xDF, 0xA3],
            ebmlElem(const [0x42, 0x82], utf8.encode('matroska')),
          );
          final infoChildren = <int>[
            if (infoTitle != null)
              ...ebmlElem(const [0x7B, 0xA9], utf8.encode(infoTitle)),
          ];
          final segBody = <int>[
            if (infoChildren.isNotEmpty)
              ...ebmlElem(const [0x15, 0x49, 0xA9, 0x66], infoChildren),
            if (tagElements.isNotEmpty)
              ...ebmlElem(
                const [0x12, 0x54, 0xC3, 0x67],
                tagElements.expand((e) => e).toList(),
              ),
          ];
          return <int>[
            ...ebmlHeader,
            ...ebmlElem(const [0x18, 0x53, 0x80, 0x67], segBody),
          ];
        }

        final dir = Directory.systemTemp.createTempSync('marco_mkv_scope_');
        addTearDown(() => dir.deleteSync(recursive: true));

        // 1. Track-only audio tags (TagTrackUID != 0) MUST be ignored!
        final trackOnlyPath = '${dir.path}/track-only.mkv';
        File(trackOnlyPath).writeAsBytesSync(
          buildMkv(
            tagElements: <List<int>>[
              ebmlElem(
                const [0x73, 0x73],
                <int>[
                  ...ebmlElem(
                    const [0x63, 0xC0],
                    ebmlElem(const [0x63, 0xC5], const [0x01, 0x02, 0x03, 0x04]),
                  ),
                  ...simpleTag('SEASON', '2'),
                  ...simpleTag('EPISODE', '10'),
                ],
              ),
            ],
          ),
        );
        final trackOnlyTags = ContainerMetadataReader.readLocalFileTagsSync(trackOnlyPath);
        expect(trackOnlyTags['season'], isNull);
        expect(trackOnlyTags['episode'], isNull);
        final trackOnlyInfo = SeriesScraper.scrapeEpisode(
          CmsEpisode(name: 'track-only.mkv', url: trackOnlyPath),
          seriesTitle: 'Example',
        );
        expect(trackOnlyInfo.status, EpisodeRecognitionStatus.needsConfirmation);
        expect(trackOnlyInfo.displayLabel, '待确认');
        expect(trackOnlyInfo.resolvedEpisodeNumber, isNull);

        // 2. Global tags (empty Targets) MUST resolve to S02E10!
        final globalPath = '${dir.path}/global.mkv';
        File(globalPath).writeAsBytesSync(
          buildMkv(
            tagElements: <List<int>>[
              ebmlElem(
                const [0x73, 0x73],
                <int>[
                  ...ebmlElem(const [0x63, 0xC0], const <int>[]),
                  ...simpleTag('SEASON', '2'),
                  ...simpleTag('EPISODE', '10'),
                ],
              ),
            ],
          ),
        );
        final globalInfo = SeriesScraper.scrapeEpisode(
          CmsEpisode(name: 'global.mkv', url: globalPath),
          seriesTitle: 'Example',
        );
        expect(globalInfo.seasonNumber, 2);
        expect(globalInfo.resolvedEpisodeNumber, 10);
        expect(globalInfo.displayLabel, 'S02E10');

        // 3. Conflicting global Info.Title ("Example S02E10") vs EPISODE="2" -> 待确认!
        final conflictPath = '${dir.path}/conflict.mkv';
        File(conflictPath).writeAsBytesSync(
          buildMkv(
            infoTitle: 'Example S02E10',
            tagElements: <List<int>>[
              ebmlElem(
                const [0x73, 0x73],
                <int>[
                  ...ebmlElem(const [0x63, 0xC0], const <int>[]),
                  ...simpleTag('SEASON', '2'),
                  ...simpleTag('EPISODE', '2'),
                ],
              ),
            ],
          ),
        );
        final conflictInfo = SeriesScraper.scrapeEpisode(
          CmsEpisode(name: 'conflict.mkv', url: conflictPath),
          seriesTitle: 'Example',
        );
        expect(conflictInfo.hasConflict, isTrue);
        expect(conflictInfo.status, EpisodeRecognitionStatus.needsConfirmation);
        expect(conflictInfo.displayLabel, '待确认');
        expect(conflictInfo.resolvedEpisodeNumber, isNull);

        // 4. Netdisk path `Season 2/E02.mkv` inside mmcloud URL/playbackSession preserves Season 2!
        const cloudEp = CmsEpisode(
          name: 'E02.mkv',
          url: 'mmcloud://uc?fid=foo&name=E02.mkv&path=%2FTV%2FSeason+2%2FE02.mkv',
          playbackSession: <String, dynamic>{
            'provider': 'uc',
            'fileName': 'E02.mkv',
            'path': '/TV/Season 2/E02.mkv',
          },
        );
        final cloudInfo = SeriesScraper.scrapeEpisode(cloudEp, seriesTitle: 'Example');
        expect(cloudInfo.seasonNumber, 2);
        expect(cloudInfo.resolvedEpisodeNumber, 2);
        expect(cloudInfo.displayLabel, 'S02E02');
      },
    );

    testWidgets(
      'P1 CMS missing episode name -> Player -> real Danmu service binds 210 (not 101), opaque URL -> 待确认, and container SHOW tag propagates into HTTP query',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // 1. Real CMS parser response where item 1 omits episode name before `$`
        final cmsVideo = CmsParser.parseListing(
          jsonEncode(<String, dynamic>{
            'list': <Map<String, dynamic>>[
              <String, dynamic>{
                'vod_id': 'cms_e7',
                'vod_name': '山中之花',
                'vod_play_from': 'main',
                'vod_play_url':
                    r'$https://cdn.example/Season%202/Show.S02E10.mp4#$https://cdn.example/stream/opaque-clip.mp4',
              },
            ],
          }),
        ).videos.first;
        expect(cmsVideo.lines.first.episodes[0].name, '第 1 集');
        expect(cmsVideo.lines.first.episodes[0].nameIsGenerated, isTrue);
        expect(cmsVideo.lines.first.episodes[0].originalFileName, 'Show.S02E10.mp4');
        expect(cmsVideo.lines.first.episodes[1].nameIsGenerated, isTrue);

        // Opaque URL with generated name has NO reliable episode evidence -> 待确认!
        final opaqueScrape = SeriesScraper.scrapeEpisode(
          cmsVideo.lines.first.episodes[1],
          originalIndex: 1,
          seriesTitle: cmsVideo.title,
        );
        expect(opaqueScrape.status, EpisodeRecognitionStatus.needsConfirmation);
        expect(opaqueScrape.displayLabel, '待确认');
        expect(opaqueScrape.resolvedEpisodeNumber, isNull);

        // 2. Drive real PlayerScreen + DandanplayProvider MockClient for item 0 (Show.S02E10.mp4)
        final matchBodies = <String>[];
        final mockDanmuHttp = MockClient((req) async {
          if (req.url.path == '/api/v2/match') {
            matchBodies.add(req.body);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'isMatched': false,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 101,
                    'animeId': 77,
                    'animeTitle': '山中之花',
                    'episodeTitle': '第1集',
                  },
                  <String, dynamic>{
                    'episodeId': 210,
                    'animeId': 77,
                    'animeTitle': '山中之花 第二季',
                    'episodeTitle': 'S02E10',
                  },
                ],
              }),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          if (req.url.path.startsWith('/api/v2/comment/')) {
            return http.Response(
              jsonEncode(<String, dynamic>{'comments': <dynamic>[]}),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        });

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            OnboardingPrefs.playHintDismissedKey: true,
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          },
        );
        final player = _Round3FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(
                key: 'cms_site',
                name: 'CMS',
                type: 1,
                api: 'https://cms.invalid',
              ),
              video: cmsVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugOnboardingPrefs: OnboardingPrefs(
                _IsolatedSharedPreferences(const <String, Object>{
                  OnboardingPrefs.playHintDismissedKey: true,
                  OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                }),
              ),
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://comments.example',
              ),
              debugDanmuProviderFactory: (s) => DandanplayProvider(
                multilineServerUrls: s.serverUrls,
                client: mockDanmuHttp,
                minRequestIntervalMs: 0,
              ),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        final danmuLayer = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        final boundSession =
            danmuLayer.segmentCache?.currentSession?.boundEpisodeId ?? '';
        expect(
          boundSession,
          DandanplayProvider.encodeBoundEpisodeId(
            'https://comments.example',
            '210',
          ),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await player.dispose();

        // 3. Container SHOW tag ("远航之夜") overrides catalog ("山中之花") in actual HTTP query
        //    AND unrelated work ("完全无关的作品 S02E10") stays candidate-only (never auto-binds)!
        final showBodies = <String>[];
        final showMockHttp = MockClient((req) async {
          if (req.url.path == '/api/v2/match') {
            showBodies.add(req.body);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'isMatched': false,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 999,
                    'animeId': 99,
                    'animeTitle': '完全无关的作品 第二季',
                    'episodeTitle': 'S02E10',
                  },
                ],
              }),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'animes': <dynamic>[]}),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        });
        final player2 = _Round3FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: const CmsSite(
                key: 'show_site',
                name: 'Show',
                type: 1,
                api: 'https://show.invalid',
              ),
              video: const CmsVideo(
                id: 'v_show',
                title: '山中之花',
                lines: <CmsLine>[
                  CmsLine(
                    name: '主线',
                    episodes: <CmsEpisode>[
                      CmsEpisode(
                        name: 'clip-A.mkv',
                        url: 'https://cdn.example/clip-A.mkv',
                        containerTags: <String, String>{
                          'show': '远航之夜',
                          'season': '2',
                          'episode': '10',
                        },
                      ),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: player2,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugOnboardingPrefs: OnboardingPrefs(
                _IsolatedSharedPreferences(const <String, Object>{
                  OnboardingPrefs.playHintDismissedKey: true,
                  OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                }),
              ),
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://comments.example',
              ),
              debugDanmuProviderFactory: (s) => DandanplayProvider(
                multilineServerUrls: s.serverUrls,
                client: showMockHttp,
                minRequestIntervalMs: 0,
              ),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        expect(showBodies, isNotEmpty);
        final reqJson = jsonDecode(showBodies.first) as Map<String, dynamic>;
        expect(reqJson['fileName'], '远航之夜 S02E10');
        final layer2 = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        // Unrelated work ("完全无关的作品") must NEVER auto-bind!
        expect(layer2.segmentCache?.currentSession?.boundEpisodeId ?? '', isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await player2.dispose();
      },
    );

    testWidgets(
      'P1 Manual danmu choice survives save/refresh/restart at current playback time, conflicting season line switch prompts picker, and sorted+hidden Prev/Next/N/auto-next skip hidden trailer',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            OnboardingPrefs.playHintDismissedKey: true,
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
          },
        );
        final navDir = Directory.systemTemp.createTempSync('marco_nav_test_');
        addTearDown(() => navDir.deleteSync(recursive: true));
        final s2e02Path = '${navDir.path}/s2e02.mp4';
        final trailerPath = '${navDir.path}/trailer.mp4';
        final s2e01Path = '${navDir.path}/s2e01.mp4';
        final s1e01Path = '${navDir.path}/s1e01.mp4';
        for (final p in <String>[s2e02Path, trailerPath, s2e01Path, s1e01Path]) {
          File(p).writeAsBytesSync(const <int>[0, 1, 2]);
        }

        const site = CmsSite(
          key: 's_nav',
          name: 'Nav',
          type: 1,
          api: 'https://nav.invalid',
        );
        final video = CmsVideo(
          id: 'v_nav',
          title: '山中之花',
          lines: <CmsLine>[
            CmsLine(
              name: '主线',
              episodes: <CmsEpisode>[
                CmsEpisode(name: 'Show.S02E02.mkv', url: s2e02Path),
                CmsEpisode(name: '预告.mkv', url: trailerPath),
                CmsEpisode(name: 'Show.S02E01.mkv', url: s2e01Path),
              ],
            ),
            CmsLine(
              name: '仅第一季备用',
              episodes: <CmsEpisode>[
                CmsEpisode(name: 'Show.S01E01.mkv', url: s1e01Path),
              ],
            ),
          ],
        );
        await storage.saveSeriesScrapeOverride(
          site.key,
          video.id,
          const SeriesScrapeOverride(
            sortByScrapedEpisode: true,
            hideSpecials: true,
          ),
        );

        final fetchedSegments = <({String epId, int seg})>[];
        final mockDanmuHttp = MockClient((req) async {
          if (req.url.path == '/api/v2/match') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'isMatched': false,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'episodeId': 999,
                    'animeId': 77,
                    'animeTitle': '山中之花 第二季',
                    'episodeTitle': 'S02E09',
                  },
                ],
              }),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          if (req.url.path == '/api/v2/bangumi/77') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'bangumi': <String, dynamic>{
                  'animeId': 77,
                  'animeTitle': '山中之花 第二季',
                  'episodes': <Map<String, dynamic>>[
                    <String, dynamic>{'episodeId': 888, 'episodeTitle': '预告'},
                    <String, dynamic>{'episodeId': 999, 'episodeTitle': 'S02E09'},
                  ],
                },
              }),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          if (req.url.path.startsWith('/api/v2/comment/')) {
            final epId = req.url.pathSegments.last;
            fetchedSegments.add((epId: epId, seg: 0));
            return http.Response(
              jsonEncode(<String, dynamic>{
                'comments': <Map<String, dynamic>>[
                  <String, dynamic>{'p': '120.5,1,16777215', 'm': '手动绑定弹幕'},
                ],
              }),
              200,
              headers: const <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        });

        // Start on raw index 2 (S02E01) at t=120s
        final player = _Round3FakePlayer();
        player.stateImpl.positionValue = const Duration(seconds: 120);
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 2,
              initialPositionMs: 120000,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugOnboardingPrefs: OnboardingPrefs(
                _IsolatedSharedPreferences(const <String, Object>{
                  OnboardingPrefs.playHintDismissedKey: true,
                  OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                }),
              ),
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://comments.example',
              ),
              debugDanmuProviderFactory: (s) => DandanplayProvider(
                multilineServerUrls: s.serverUrls,
                client: mockDanmuHttp,
                minRequestIntervalMs: 0,
              ),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // 1. Neighbor-only candidate 999 was NOT auto-bound initially.
        final layerInit = tester.widget<DanmuLayer>(find.byType(DanmuLayer));
        expect(layerInit.segmentCache?.currentSession?.boundEpisodeId ?? '', isEmpty);

        // Open Episodes -> Calibrate -> pick low-confidence candidate 999
        await tester.tap(find.text('选集'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.byKey(const ValueKey('player-episode-calibrate-btn')));
        await tester.pump(const Duration(milliseconds: 250));
        final cand999 = DandanplayProvider.encodeBoundEpisodeId(
          'https://comments.example',
          '999',
        );
        final candChip = find.byKey(ValueKey('scrape-danmu-cand-$cand999'));
        expect(candChip, findsOneWidget);
        await tester.tap(candChip);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));

        // 2. Manual choice stays bound after save & refresh!
        expect(
          tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId,
          cand999,
        );
        expect(fetchedSegments.any((f) => f.epId == '999'), isTrue);

        // Trigger revision refresh (simulating saving calibration sheet / refresh)
        storage.seriesScrapeRevision.value++;
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId,
          cand999,
        );

        // 3. Conflicting season line switch: S02E01 -> line "仅第一季备用" (only S01E01)
        //    Must NOT auto-open s1e01.mp4; must stay on s2e01.mp4 & open picker!
        await tester.tap(find.byKey(const Key('desktop-more-button')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('切换线路'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('仅第一季备用'));
        await tester.pump(const Duration(milliseconds: 250));
        expect(player.openedUris.last.replaceAll('\\', '/'), s2e01Path.replaceAll('\\', '/'));
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        // Dismiss episode picker
        Navigator.of(tester.element(find.byType(PlayerEpisodePickerSheet))).pop();
        await tester.pump(const Duration(milliseconds: 200));

        // 4. N key follows visible sorted+hidden order: S02E01 -> S02E02 (skipping hidden 预告!)
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 250));
        expect(player.openedUris.last.replaceAll('\\', '/'), s2e02Path.replaceAll('\\', '/'));

        // Pressing N at last visible episode (S02E02) does NOT jump into hidden 预告!
        final countBeforeEndN = player.openedUris.length;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
        await tester.pump(const Duration(milliseconds: 200));
        expect(player.openedUris.length, countBeforeEndN);

        // P key returns to S02E01
        await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
        await tester.pump(const Duration(milliseconds: 250));
        expect(player.openedUris.last.replaceAll('\\', '/'), s2e01Path.replaceAll('\\', '/'));

        // Auto-play-next on completion follows visible order -> S02E02 (NOT 预告!)
        player.streamImpl.completedCtrl.add(true);
        await tester.pump(const Duration(milliseconds: 250));
        expect(player.openedUris.last.replaceAll('\\', '/'), s2e02Path.replaceAll('\\', '/'));

        // 5. Restart / remount PlayerScreen on S02E01 -> persisted manual binding 999 still active!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await player.dispose();

        final playerRestart = _Round3FakePlayer();
        playerRestart.stateImpl.positionValue = const Duration(seconds: 120);
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 2,
              initialPositionMs: 120000,
              storage: storage,
              debugPlayer: playerRestart,
              debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
              debugOnboardingPrefs: OnboardingPrefs(
                _IsolatedSharedPreferences(const <String, Object>{
                  OnboardingPrefs.playHintDismissedKey: true,
                  OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                }),
              ),
              debugDanmuSettings: const DanmuSettings(
                enabled: true,
                serverUrls: 'https://comments.example',
              ),
              debugDanmuProviderFactory: (s) => DandanplayProvider(
                multilineServerUrls: s.serverUrls,
                client: mockDanmuHttp,
                minRequestIntervalMs: 0,
              ),
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId,
          cand999,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await playerRestart.dispose();
      },
    );

    test(
      'P1 WebDAV Safety: in-flight PUT edit preserved, 5x ETag 412 never drops preconditions, unknown schema/missing sources rejected, per-origin headers isolated on both endpoints, disabled retry sends 0 calls',
      () async {
        const oldOrigin = 'https://old.example';
        const editedOrigin = 'https://edited.example';
        const restoredOrigin = 'https://restored.example';
        const davUrl = 'https://dav.example/dav/family.json';

        // 1. Unknown schemaVersion & missing sources both fail without wiping local
        for (final badBody in <String>[
          jsonEncode(<String, dynamic>{
            'schemaVersion': 2,
            'updatedAt': 999999,
            'serversV2': <String>['https://future.example'],
          }),
          jsonEncode(<String, dynamic>{
            'schemaVersion': 1,
            'updatedAt': 999999,
          }),
        ]) {
          final storage = await initTestStorage();
          await storage.saveWebdavConfig(
            url: davUrl,
            user: 'u',
            pass: 'p',
            auto: false,
            syncSubs: false,
            syncHistory: false,
            syncDanmu: true,
          );
          await DanmuPrefs.save(
            const DanmuSettings(serverUrls: oldOrigin),
            triggerSync: false,
          );
          final badClient = MockClient((req) async {
            if (req.url.path.endsWith('family.danmu.json')) {
              return http.Response(badBody, 200, headers: const {'etag': '"v-bad"'});
            }
            return http.Response('', 404);
          });
          await expectLater(
            () => storage.syncDanmuSourcesWithWebdav(client: badClient),
            throwsA(isA<FormatException>()),
          );
          expect((await DanmuPrefs.load()).normalizedOrigins, <String>[oldOrigin]);
        }

        // 2. In-flight PUT edit preservation (`old` -> `edited` during HTTP 204)
        {
          final storage = await initTestStorage();
          await storage.saveWebdavConfig(
            url: davUrl,
            user: 'u',
            pass: 'p',
            auto: false,
            syncSubs: false,
            syncHistory: false,
            syncDanmu: true,
          );
          await DanmuPrefs.save(
            const DanmuSettings(serverUrls: oldOrigin),
            triggerSync: false,
          );
          String? serverDoc;
          int putCount = 0;
          final firstPutStarted = Completer<void>();
          final releaseFirstPut = Completer<void>();
          final client = MockClient((req) async {
            if (req.method == 'GET') {
              if (serverDoc == null) return http.Response('', 404);
              return http.Response(
                serverDoc!,
                200,
                headers: <String, String>{'etag': '"e-$putCount"'},
              );
            }
            if (req.method == 'PUT') {
              putCount++;
              if (putCount == 1) {
                firstPutStarted.complete();
                await releaseFirstPut.future;
              }
              serverDoc = req.body;
              return http.Response('', 204);
            }
            return http.Response('', 201);
          });

          final syncFuture = storage.syncDanmuSourcesWithWebdav(client: client);
          await firstPutStarted.future;
          await DanmuPrefs.save(
            const DanmuSettings(serverUrls: editedOrigin),
            triggerSync: false,
          );
          releaseFirstPut.complete();
          await syncFuture;

          expect((await DanmuPrefs.load()).normalizedOrigins, <String>[editedOrigin]);
          final finalServer = DanmuSourceSyncDocument.tryParseJson(serverDoc);
          expect(finalServer?.urls, <String>[editedOrigin]);
        }

        // 3. Five consecutive real ETag 412 conflicts MUST NOT send unconditional PUT
        {
          final storage = await initTestStorage();
          await storage.saveWebdavConfig(
            url: davUrl,
            user: 'u',
            pass: 'p',
            auto: false,
            syncSubs: false,
            syncHistory: false,
            syncDanmu: true,
          );
          await DanmuPrefs.save(
            const DanmuSettings(serverUrls: oldOrigin),
            triggerSync: false,
          );
          int peerRev = 1;
          int conflicts = 0;
          int unconditionalPuts = 0;
          String serverBody() => jsonEncode(<String, dynamic>{
                'schemaVersion': 1,
                'updatedAt': 10000 + peerRev,
                'revision': peerRev,
                'clearedAt': 0,
                'sources': <Map<String, dynamic>>[
                  <String, dynamic>{'url': 'https://peer$peerRev.example', 'requiresAuth': false},
                ],
              });
          String latestServerDoc = serverBody();
          final conflictClient = MockClient((req) async {
            if (req.method == 'GET') {
              return http.Response(
                latestServerDoc,
                200,
                headers: <String, String>{'etag': '"peer-$peerRev"'},
              );
            }
            if (req.method == 'PUT') {
              if (!req.headers.containsKey('If-Match')) {
                unconditionalPuts++;
                latestServerDoc = req.body;
                return http.Response('', 204);
              }
              conflicts++;
              peerRev++;
              latestServerDoc = serverBody();
              return http.Response('', 412);
            }
            return http.Response('', 201);
          });

          await expectLater(
            () => storage.syncDanmuSourcesWithWebdav(client: conflictClient),
            throwsA(isA<FormatException>()),
          );
          expect(conflicts, 5);
          expect(unconditionalPuts, 0);
          expect((await DanmuPrefs.load()).normalizedOrigins, <String>[oldOrigin]);
          expect(
            DanmuSourceSyncDocument.tryParseJson(latestServerDoc)?.urls,
            <String>['https://peer6.example'],
          );
        }

        // 4. Per-origin credential isolation: inspect ACTUAL headers sent to BOTH endpoints!
        {
          final storage = await initTestStorage();
          await storage.saveWebdavConfig(
            url: davUrl,
            user: 'u',
            pass: 'p',
            auto: false,
            syncSubs: false,
            syncHistory: false,
            syncDanmu: true,
          );
          await DanmuPrefs.save(
            const DanmuSettings(
              serverUrls: oldOrigin,
              appId: 'local-device-app-id',
              appSecret: 'local-device-secret',
            ),
            triggerSync: false,
          );
          final remoteWithBoth = jsonEncode(<String, dynamic>{
            'schemaVersion': 1,
            'updatedAt': DateTime.now().millisecondsSinceEpoch + 50000,
            'revision': 5,
            'clearedAt': 0,
            'sources': <Map<String, dynamic>>[
              <String, dynamic>{'url': oldOrigin, 'requiresAuth': true},
              <String, dynamic>{'url': restoredOrigin, 'requiresAuth': true},
            ],
          });
          final davClient = MockClient((req) async {
            if (req.method == 'GET') {
              return http.Response(
                remoteWithBoth,
                200,
                headers: const {'etag': '"auth-v1"'},
              );
            }
            return http.Response('', 204);
          });
          final synced = await storage.syncWithWebdav(client: davClient);
          expect(synced.danmuPendingAuthOrigins, <String>[restoredOrigin]);

          final headersByHost = <String, List<Map<String, String>>>{};
          final probeClient = MockClient((req) async {
            headersByHost
                .putIfAbsent(req.url.host, () => <Map<String, String>>[])
                .add(Map<String, String>.from(req.headers));
            // Return empty from old.example so provider also queries restored.example
            return http.Response(
              jsonEncode(<String, dynamic>{'isMatched': false, 'matches': <dynamic>[]}),
              200,
              headers: const {'content-type': 'application/json'},
            );
          });
          final loaded = await DanmuPrefs.load();
          final provider = DandanplayProvider(
            multilineServerUrls: loaded.serverUrls,
            appId: loaded.appId,
            appSecret: loaded.appSecret,
            client: probeClient,
            minRequestIntervalMs: 0,
          );
          await provider.matchOrSearch(
            const DanmuMatchQuery(
              title: '测试番剧',
              episodeTitle: 'S02E10',
              episodeIndex: 10,
              seasonNumber: 2,
            ),
          );
          // Endpoint 1 (old.example, locally authorized) RECEIVED X-AppId + X-Signature!
          expect(headersByHost['old.example'], isNotEmpty);
          expect(headersByHost['old.example']!.first['X-AppId'], 'local-device-app-id');
          expect(headersByHost['old.example']!.first['X-Signature'], isNotEmpty);
          // Endpoint 2 (restored.example, cloud-imported unapproved) RECEIVED ZERO auth headers!
          expect(headersByHost['restored.example'], isNotEmpty);
          for (final h in headersByHost['restored.example']!) {
            expect(h.containsKey('X-AppId'), isFalse);
            expect(h.containsKey('X-Signature'), isFalse);
          }

          // After explicit per-origin authorization, restored.example receives auth headers!
          await DanmuPrefs.authorizeOriginsForLocalCredentials(<String>[restoredOrigin]);
          expect(await DanmuPrefs.loadPendingAuthOrigins(), isEmpty);
          headersByHost.clear();
          final loadedAfterAuth = await DanmuPrefs.load();
          final providerAfterAuth = DandanplayProvider(
            multilineServerUrls: loadedAfterAuth.serverUrls,
            appId: loadedAfterAuth.appId,
            appSecret: loadedAfterAuth.appSecret,
            client: probeClient,
            minRequestIntervalMs: 0,
          );
          await providerAfterAuth.matchOrSearch(
            const DanmuMatchQuery(
              title: '测试番剧',
              episodeTitle: 'S02E10',
              episodeIndex: 10,
              seasonNumber: 2,
            ),
          );
          expect(
            headersByHost['restored.example']!.first['X-AppId'],
            'local-device-app-id',
          );
          expect(
            headersByHost['restored.example']!.first['X-Signature'],
            isNotEmpty,
          );

          // 5. Disabled toggle stops syncDanmuSourcesWithWebdav with 0 requests
          await storage.setWebdavSyncDanmu(false);
          int calls = 0;
          final zeroClient = MockClient((_) async {
            calls++;
            return http.Response('', 200);
          });
          await expectLater(
            () => storage.syncDanmuSourcesWithWebdav(client: zeroClient),
            throwsA(isA<FormatException>()),
          );
          expect(calls, 0);
        }
      },
    );

    testWidgets(
      'P1 WebDAV UI Scope: sync-switch-danmu is absent on iOS and Windows',
      variant: TargetPlatformVariant(<TargetPlatform>{
        TargetPlatform.iOS,
        TargetPlatform.windows,
      }),
      (tester) async {
        final storage = await initTestStorage();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CloudSyncSettingsPanel(
                  storage: storage,
                  embeddedInList: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('sync-switch-danmu')), findsNothing);
      },
    );
  });

  // =========================================================================
  // REWORK REGRESSIONS (Post-2fec7f0 Independent Review Counterexamples)
  // =========================================================================
  group('Post-2fec7f0 Rework: WebDAV Rebase, Settings Guards, Danmu Ambiguity & Scoped MKV', () {
    test(
      'WebDAV 3-way rebase preserves peer R when local adds C during PUT, and still propagates deliberate deletion of R',
      () async {
        const baseUrl = 'https://base-a.example';
        const localL = 'https://local-l.example';
        const peerR = 'https://peer-r.example';
        const localC = 'https://local-c.example';

        DanmuSourceSyncDocument mkDoc(List<String> urls, int rev) =>
            DanmuSourceSyncDocument(
              initialized: true,
              updatedAt: rev,
              revision: rev,
              sources: [for (final u in urls) DanmuSyncSourceEntry(url: u)],
            );

        // Scenario 1: Local adds L, peer adds R; while PUT #1 ([A,L,R]) is in
        // flight, local adds C -> final local & remote MUST retain [A, L, R, C].
        final storage = await initTestStorage();
        await storage.saveWebdavConfig(
          url: 'https://dav.example/family.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        final sp = await SharedPreferences.getInstance();
        await DanmuPrefs.applySyncedDocument(
          mkDoc([baseUrl], 1),
          prefs: sp,
          pendingAuthOrigins: const <String>[],
        );
        await DanmuPrefs.save(const DanmuSettings(serverUrls: '$baseUrl\n$localL'));

        var remote = mkDoc([baseUrl, peerR], 2);
        final firstPut = Completer<void>();
        final release = Completer<void>();
        final sent = <List<String>>[];
        final client = MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              remote.toPayloadJson(),
              200,
              headers: {'etag': '"r${remote.revision}"'},
            );
          }
          final incoming = DanmuSourceSyncDocument.tryParseJson(req.body)!;
          sent.add(incoming.urls);
          if (sent.length == 1) {
            firstPut.complete();
            await release.future;
          }
          remote = incoming;
          return http.Response('', 204);
        });

        final syncFut = storage.syncWithWebdav(client: client);
        await firstPut.future;
        expect(sent.first, containsAll(<String>[baseUrl, localL, peerR]));
        final mid = await DanmuPrefs.load();
        await DanmuPrefs.save(mid.copyWith(serverUrls: '$baseUrl\n$localL\n$localC'));
        release.complete();
        final res = await syncFut;
        final afterLocal = (await DanmuPrefs.load()).normalizedOrigins;
        expect(res.danmuSynced, isTrue);
        expect(afterLocal, containsAll(<String>[baseUrl, localL, peerR, localC]));
        expect(remote.urls, containsAll(<String>[baseUrl, localL, peerR, localC]));

        // Scenario 2: User has now seen R and explicitly deletes R -> deletion propagates!
        final loadedWithR = await DanmuPrefs.load();
        await DanmuPrefs.save(
          loadedWithR.copyWith(
            serverUrls: afterLocal.where((u) => u != peerR).join('\n'),
          ),
        );
        final delRes = await storage.syncWithWebdav(client: client);
        final finalLocal = (await DanmuPrefs.load()).normalizedOrigins;
        expect(delRes.danmuSynced, isTrue);
        expect(finalLocal, containsAll(<String>[baseUrl, localL, localC]));
        expect(finalLocal, isNot(contains(peerR)));
        expect(remote.urls, containsAll(<String>[baseUrl, localL, localC]));
        expect(remote.urls, isNot(contains(peerR)));
      },
    );

    testWidgets(
      'DanmuSettingsSheet: opacity edit preserves cloud restore, dismissed auth stays unassociated on save, and per-row auth toggle works',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const oldUrl = 'https://original.example';
        const peerUrl = 'https://remote.example';
        const manualUrl = 'https://manual.example';

        tester.view.physicalSize = const Size(1000, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // 1. Open sheet, cloud restores peerUrl, user only changes opacity -> peerUrl preserved!
        final s1 = await initTestStorage();
        await s1.saveWebdavConfig(
          url: 'https://dav.example/family.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        final sp1 = await SharedPreferences.getInstance();
        await DanmuPrefs.applySyncedDocument(
          const DanmuSourceSyncDocument(
            initialized: true,
            revision: 1,
            updatedAt: 1,
            sources: [DanmuSyncSourceEntry(url: oldUrl, requiresAuth: true)],
          ),
          prefs: sp1,
          pendingAuthOrigins: const <String>[],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmuSettingsSheet(
                key: const ValueKey('danmu-settings-sheet-opacity'),
                initialSettings: await DanmuPrefs.load(),
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await s1.syncWithWebdav(
          client: MockClient(
            (_) async => http.Response(
              const DanmuSourceSyncDocument(
                initialized: true,
                revision: 5,
                updatedAt: 5,
                sources: [DanmuSyncSourceEntry(url: peerUrl, requiresAuth: true)],
              ).toPayloadJson(),
              200,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final slider = find.byType(Slider).first;
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        final tapPt = tester.getTopLeft(slider) +
            Offset(tester.getSize(slider).width * 0.4, tester.getSize(slider).height / 2);
        await tester.tapAt(tapPt);
        await tester.pumpAndSettle();
        final afterOpacity = await DanmuPrefs.load();
        expect(afterOpacity.opacity, isNot(0.85));
        expect(afterOpacity.serverUrls, peerUrl);

        // 2. Dismiss pending auth -> edit multiline URLs adding manualUrl -> save -> peerUrl stays unauthorized!
        final s2 = await initTestStorage();
        await s2.saveWebdavConfig(
          url: 'https://dav.example/family.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.save(
          const DanmuSettings(serverUrls: oldUrl, appId: 'mock', appSecret: 'dummy'),
        );
        await s2.syncWithWebdav(
          client: MockClient(
            (req) async => req.method == 'GET'
                ? http.Response(
                    const DanmuSourceSyncDocument(
                      initialized: true,
                      revision: 6,
                      updatedAt: 6,
                      sources: [
                        DanmuSyncSourceEntry(url: oldUrl, requiresAuth: true),
                        DanmuSyncSourceEntry(url: peerUrl, requiresAuth: true),
                      ],
                    ).toPayloadJson(),
                    200,
                  )
                : http.Response('', 204),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmuSettingsSheet(
                key: const ValueKey('danmu-settings-sheet-dismiss-auth'),
                initialSettings: await DanmuPrefs.load(),
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dismissBtn = find.byKey(const Key('danmu-pending-auth-dismiss'));
        await tester.ensureVisible(dismissBtn);
        await tester.tap(dismissBtn);
        await tester.pumpAndSettle();

        final urlsField = find.byKey(const Key('danmu-server-urls-field'));
        await tester.ensureVisible(urlsField);
        await tester.enterText(urlsField, '$oldUrl\n$peerUrl\n$manualUrl');
        final saveBtn = find.byKey(const Key('danmu-save-server-btn'));
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pumpAndSettle();

        final trusted = (await DanmuPrefs.load()).authorizedCredentialOrigins!;
        expect(trusted, containsAll(<String>[oldUrl, manualUrl]));
        expect(trusted, isNot(contains(peerUrl)));

        // Explicit per-row auth toggle grants peerUrl authorization cleanly.
        final rowAuthBtn = find.byKey(const Key('danmu-source-auth-1'));
        await tester.ensureVisible(rowAuthBtn);
        await tester.tap(rowAuthBtn);
        await tester.pumpAndSettle();
        expect(
          (await DanmuPrefs.load()).authorizedCredentialOrigins!,
          contains(peerUrl),
        );
      },
    );

    test(
      'WebDAV switch-off mid-GET sends 0 PUTs, incomplete empty JSON rejected vs explicit clear & fresh join, and 302 redirect strips creds on unapproved origin',
      () async {
        const oldUrl = 'https://original.example';

        // 1. Disable sync while GET awaits -> 0 PUTs!
        final s1 = await initTestStorage();
        await s1.saveWebdavConfig(
          url: 'https://dav.example/family.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.save(const DanmuSettings(serverUrls: oldUrl));
        final getStarted = Completer<void>();
        final releaseGet = Completer<void>();
        int puts = 0;
        final syncRun = s1.syncWithWebdav(
          client: MockClient((req) async {
            if (req.method == 'GET') {
              getStarted.complete();
              await releaseGet.future;
              return http.Response('', 404);
            }
            if (req.method == 'PUT') puts++;
            return http.Response('', 204);
          }),
        );
        await getStarted.future;
        await s1.setWebdavSyncDanmu(false);
        releaseGet.complete();
        await expectLater(syncRun, throwsA(isA<FormatException>()));
        expect(puts, 0);

        // 2. Incomplete empty file {"schemaVersion":1,"sources":[]} must NOT wipe local sources.
        final s2 = await initTestStorage();
        await s2.saveWebdavConfig(
          url: 'https://dav.example/family.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.applySyncedDocument(
          const DanmuSourceSyncDocument(
            initialized: true,
            revision: 1,
            updatedAt: 1,
            sources: [DanmuSyncSourceEntry(url: oldUrl)],
          ),
          prefs: await SharedPreferences.getInstance(),
          pendingAuthOrigins: const <String>[],
        );
        await expectLater(
          () => s2.syncWithWebdav(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({'schemaVersion': 1, 'sources': <dynamic>[]}),
                200,
              ),
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        expect((await DanmuPrefs.load()).serverUrls, oldUrl);

        // Explicit deliberate clear (clearedAt > 0) DOES propagate!
        final clearRes = await s2.syncWithWebdav(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'updatedAt': 999999,
                'revision': 5,
                'clearedAt': 999999,
                'sources': <dynamic>[],
              }),
              200,
            ),
          ),
        );
        expect(clearRes.danmuSynced, isTrue);
        expect((await DanmuPrefs.load()).normalizedOrigins, isEmpty);

        // 3. HTTP 302 redirect from authorized origin to unapproved configured origin must NOT send X-AppId/X-Signature!
        const authOrigin = 'https://auth.example';
        const unapprovedOrigin = 'https://unapproved.example';
        final headersByHost = <String, Map<String, String>>{};
        final redirectProvider = DandanplayProvider(
          multilineServerUrls: '$authOrigin\n$unapprovedOrigin',
          appId: 'my-app',
          appSecret: 'my-secret',
          authorizedCredentialOrigins: const <String>{authOrigin},
          minRequestIntervalMs: 0,
          client: MockClient((req) async {
            headersByHost[req.url.host] = Map<String, String>.from(req.headers);
            if (req.url.host == 'auth.example') {
              return http.Response(
                '',
                302,
                headers: {'location': '$unapprovedOrigin/api/v2/comment/42'},
              );
            }
            return http.Response('{"count":0,"comments":[]}', 200);
          }),
        );
        addTearDown(redirectProvider.close);
        await redirectProvider.openSession(
          DandanplayProvider.encodeBoundEpisodeId(authOrigin, '42'),
        );
        expect(headersByHost['auth.example']?['X-AppId'], 'my-app');
        expect(headersByHost['unapproved.example']?.containsKey('X-AppId'), isFalse);
        expect(headersByHost['unapproved.example']?.containsKey('X-Signature'), isFalse);
      },
    );

    test(
      'Matroska hierarchical TargetTypeValue (70/60/50) preserves Collection title, Season PART_NUMBER=2, and Episode PART_NUMBER=10',
      () {
        final tmp = Directory.systemTemp.createTempSync('marco_scoped_mkv_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        Uint8List mkTagGroup(int level, Map<String, String> fields) {
          final body = BytesBuilder(copy: false)
            ..add(
              _ebmlElement(
                const <int>[0x63, 0xC0],
                _ebmlElement(const <int>[0x68, 0xCA], <int>[level]),
              ),
            );
          for (final e in fields.entries) {
            final st = BytesBuilder(copy: false)
              ..add(_ebmlElement(const <int>[0x45, 0xA3], utf8.encode(e.key)))
              ..add(_ebmlElement(const <int>[0x44, 0x87], utf8.encode(e.value)));
            body.add(_ebmlElement(const <int>[0x67, 0xC8], st.toBytes()));
          }
          return _ebmlElement(const <int>[0x73, 0x73], body.toBytes());
        }

        final header = _ebmlElement(
          const <int>[0x1A, 0x45, 0xDF, 0xA3],
          _ebmlElement(const <int>[0x42, 0x82], utf8.encode('matroska')),
        );
        final tagsPayload = (BytesBuilder(copy: false)
              ..add(mkTagGroup(70, const {'TITLE': 'The Series'}))
              ..add(mkTagGroup(60, const {'PART_NUMBER': '2'}))
              ..add(mkTagGroup(50, const {'TITLE': 'A Quiet Journey', 'PART_NUMBER': '10'})))
            .toBytes();
        final segment = _ebmlElement(
          const <int>[0x18, 0x53, 0x80, 0x67],
          _ebmlElement(const <int>[0x12, 0x54, 0xC3, 0x67], tagsPayload),
        );
        final clip = File('${tmp.path}/clip.mkv')
          ..writeAsBytesSync((BytesBuilder(copy: false)..add(header)..add(segment)).toBytes());

        final tags = ContainerMetadataReader.readLocalFileTagsSync(clip.path);
        expect(tags['show'], 'The Series');
        expect(tags['season_number'], '2');
        expect(tags['episode_number'], '10');
        expect(tags['title'], 'A Quiet Journey');

        final scraped = SeriesScraper.scrapeEpisode(
          CmsEpisode(name: 'clip.mkv', url: clip.path),
        );
        expect(scraped.recognizedWorkTitle, 'The Series');
        expect(scraped.seasonNumber, 2);
        expect(scraped.resolvedEpisodeNumber, 10);
        expect(scraped.displayLabel, 'S02E10');
      },
    );

    testWidgets(
      'Danmu identity ambiguity (reversed S01E10/S02E10), non-exact ID/title-only candidates, CMS label vs file conflict, and unknown-season line switch',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const origin = 'https://comments.example';
        const site = CmsSite(key: 'rev', name: 'Rev', type: 1, api: 'https://cdn.example/api');
        final tmp = Directory.systemTemp.createTempSync('marco_danmu_rework_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        CmsEpisode mkEp(String label, String stem) {
          final f = File('${tmp.path}/$stem.mp4')..writeAsBytesSync(const [0, 1, 2, 3]);
          return CmsEpisode(name: label, url: f.path);
        }

        Future<String?> mountAndGetBound(
          List<CmsLine> lines,
          DandanplayProvider provider, {
          _Round3FakePlayer? customPlayer,
        }) async {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final storage = await initTestStorage();
          final player = customPlayer ?? _Round3FakePlayer();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
              home: PlayerScreen(
                site: site,
                video: CmsVideo(id: 'movie', title: '山中之花', lines: lines),
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                storage: storage,
                debugPlayer: player,
                debugVideoSurface: const SizedBox.shrink(),
                debugDanmuProvider: provider,
                debugDanmuSettings: const DanmuSettings(enabled: true, serverUrls: origin),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump(const Duration(milliseconds: 100));
          final bound = tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 450));
          return bound;
        }

        // 1. Ambiguous S01E10 (110) vs S02E10 (210) in BOTH orders -> neither auto-binds!
        for (final reversed in const [false, true]) {
          final matches = reversed
              ? const [
                  {'episodeId': 210, 'animeId': 2, 'animeTitle': '山中之花 第二季', 'episodeTitle': 'S02E10'},
                  {'episodeId': 110, 'animeId': 1, 'animeTitle': '山中之花 第一季', 'episodeTitle': 'S01E10'},
                ]
              : const [
                  {'episodeId': 110, 'animeId': 1, 'animeTitle': '山中之花 第一季', 'episodeTitle': 'S01E10'},
                  {'episodeId': 210, 'animeId': 2, 'animeTitle': '山中之花 第二季', 'episodeTitle': 'S02E10'},
                ];
          final p = DandanplayProvider(
            multilineServerUrls: origin,
            minRequestIntervalMs: 0,
            client: MockClient((req) async {
              if (req.url.path.contains('/search/')) return http.Response('{"animes":[]}', 200);
              return http.Response.bytes(
                utf8.encode(jsonEncode({'isMatched': false, 'matches': matches})),
                200,
              );
            }),
          );
          addTearDown(p.close);
          final b = await mountAndGetBound(
            [CmsLine(name: 'A', episodes: [mkEp('第10集', 'no-season')])],
            p,
          );
          expect(b, isNull, reason: 'reversed=$reversed must leave ambiguous seasons for user choice');
        }

        // 2. Non-exact ID-only (83) and title-only ("重逢", 84) -> neither auto-binds!
        for (final matchEntry in const [
          {'episodeId': 83, 'animeId': 37},
          {'episodeId': 84, 'animeId': 37, 'animeTitle': '山中之花', 'episodeTitle': '重逢'},
        ]) {
          final p = DandanplayProvider(
            multilineServerUrls: origin,
            minRequestIntervalMs: 0,
            client: MockClient((req) async {
              if (req.url.path.contains('/search/')) return http.Response('{"animes":[]}', 200);
              return http.Response.bytes(
                utf8.encode(jsonEncode({'isMatched': false, 'matches': [matchEntry]})),
                200,
              );
            }),
          );
          addTearDown(p.close);
          final b = await mountAndGetBound(
            [CmsLine(name: '主', episodes: [mkEp('S02E10', 'target')])],
            p,
          );
          expect(b, isNull);
        }

        // 3. CMS display name "第 1 集" vs real file Season.2/show.S02E10.mp4 -> conflict 待确认, never binds 201!
        final parsed = CmsParser.parseListing(
          jsonEncode({
            'list': [
              {
                'vod_id': 'movie',
                'vod_name': '山中之花',
                'vod_play_from': 'cloud',
                'vod_play_url': r'第 1 集$https://cdn.example/Season.2/show.S02E10.mp4',
              },
            ],
          }),
        );
        final cmsEp = parsed.videos.single.lines.single.episodes.single;
        final scrapedCms = SeriesScraper.scrapeEpisode(cmsEp, seriesTitle: '山中之花');
        expect(scrapedCms.hasConflict, isTrue);
        expect(scrapedCms.needsConfirmation, isTrue);
        final pCms = DandanplayProvider(
          multilineServerUrls: origin,
          minRequestIntervalMs: 0,
          client: MockClient((req) async {
            if (req.url.path.contains('/search/')) return http.Response('{"animes":[]}', 200);
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'isMatched': true,
                  'matches': [
                    {'episodeId': 201, 'animeId': 2, 'animeTitle': '山中之花 第二季', 'episodeTitle': 'S02E01'},
                    {'episodeId': 210, 'animeId': 2, 'animeTitle': '山中之花 第二季', 'episodeTitle': 'S02E10'},
                  ],
                }),
              ),
              200,
            );
          }),
        );
        addTearDown(pCms.close);
        final boundCms = await mountAndGetBound(parsed.videos.single.lines, pCms);
        expect(boundCms, isNull);

        // 4. Unknown-season E10 -> backup line only has E11 -> stay on main10 and open episode picker!
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        final storage4 = await initTestStorage();
        final player4 = _Round3FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
            home: PlayerScreen(
              site: site,
              video: CmsVideo(
                id: 'movie',
                title: '山中之花',
                lines: [
                  CmsLine(name: '主线', episodes: [mkEp('第10集', 'main10')]),
                  CmsLine(name: '缺集备线', episodes: [mkEp('第11集', 'wrong11')]),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage4,
              debugPlayer: player4,
              debugVideoSurface: const SizedBox.shrink(),
              debugDanmuSettings: const DanmuSettings(enabled: false),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('desktop-more-button')));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('切换线路'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.textContaining('缺集备线').first);
        await tester.pump(const Duration(milliseconds: 500));
        expect(player4.openedUris.last, endsWith('main10.mp4'));
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 450));
      },
    );
  });

  // =========================================================================
  // POST-ffbac25 REWORK REGRESSIONS (Work-Aware Line Switch, Trailer Guard,
  // Unique Full-Identity Danmu, Dirty Editor Baseline Merge, Reorder Preserve,
  // 409 MKCOL Abort & Fade-Out Transition)
  // =========================================================================
  group('Post-ffbac25 Rework: Work/Trailer Line Switch, Full-Match Danmu, Dirty Editor & MKCOL Abort', () {
    testWidgets(
      'Line switch checks work+season+episode in both orders, blocks trailer-only on manual switch AND failure auto-recovery, and binds unique S02E10 (210) over unseasoned E10',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const origin = 'https://comments.example';
        const site = CmsSite(key: 'rev2', name: 'Rev2', type: 1, api: 'https://cdn.example/api');
        final tmp = Directory.systemTemp.createTempSync('marco_ffbac25_ep_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        CmsEpisode mkMkv(String stem, String show) {
          final f = File('${tmp.path}/$stem.mkv')
            ..writeAsBytesSync(
              _buildMkvWithContainerTags(
                infoTitle: 'S02E10',
                simpleTags: {'SHOW': show, 'SEASON': '2', 'EPISODE': '10'},
              ),
            );
          return CmsEpisode(name: '$stem.mkv', url: f.path);
        }

        CmsEpisode mkMp4(String label, String stem) {
          final f = File('${tmp.path}/$stem.mp4')..writeAsBytesSync(const [0, 1, 2, 3]);
          return CmsEpisode(name: label, url: f.path);
        }

        Future<void> pickLine(String target) async {
          await tester.tap(find.byKey(const Key('desktop-more-button')));
          await tester.pump(const Duration(milliseconds: 250));
          await tester.tap(find.text('切换线路'));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.textContaining(target).first);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
        }

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final mainEp = mkMkv('opaque-main', '山中之花');
        final wrongWorkEp = mkMkv('opaque-wrong', '远航之夜');
        final rightWorkEp = mkMkv('opaque-correct', '山中之花');

        // 1a. Wrong-work-only backup -> stays on opaque-main.mkv and prompts picker.
        final s1 = await initTestStorage();
        final p1 = _Round3FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
            home: PlayerScreen(
              site: site,
              video: CmsVideo(
                id: 'movie',
                title: '山中之花',
                lines: [
                  CmsLine(name: '主线', episodes: [mainEp]),
                  CmsLine(name: '错剧备线', episodes: [wrongWorkEp]),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: s1,
              debugPlayer: p1,
              debugVideoSurface: const SizedBox.shrink(),
              debugDanmuSettings: const DanmuSettings(enabled: false),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        await pickLine('错剧备线');
        expect(p1.openedUris.last, endsWith('opaque-main.mkv'));
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 450));

        // 1b. Mixed backup in BOTH orders ([wrong, right] AND [right, wrong]) -> opens opaque-correct.mkv!
        for (final reversed in const [false, true]) {
          final backupEps = reversed ? [rightWorkEp, wrongWorkEp] : [wrongWorkEp, rightWorkEp];
          final p = _Round3FakePlayer();
          final s = await initTestStorage();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
              home: PlayerScreen(
                site: site,
                video: CmsVideo(
                  id: 'movie',
                  title: '山中之花',
                  lines: [
                    CmsLine(name: '主线', episodes: [mainEp]),
                    CmsLine(name: '混排备线', episodes: backupEps),
                  ],
                ),
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                storage: s,
                debugPlayer: p,
                debugVideoSurface: const SizedBox.shrink(),
                debugDanmuSettings: const DanmuSettings(enabled: false),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 450));
          await pickLine('混排备线');
          expect(
            p.openedUris.last,
            endsWith('opaque-correct.mkv'),
            reason: 'reversed=$reversed must pick matching work 山中之花 S02E10',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 450));
        }

        // 2. Regular S02E10 -> trailer-only backup: blocked on BOTH manual switch AND failure auto-recovery!
        final s2 = await initTestStorage();
        final p2 = _Round3FakePlayer();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
            home: PlayerScreen(
              site: site,
              video: CmsVideo(
                id: 'movie',
                title: '山中之花',
                lines: [
                  CmsLine(name: '常规线路', episodes: [mkMp4('S02E10', 'main10')]),
                  CmsLine(name: '预告备线', episodes: [mkMp4('预告片', 'trailer')]),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: s2,
              debugPlayer: p2,
              debugVideoSurface: const SizedBox.shrink(),
              debugDanmuSettings: const DanmuSettings(enabled: false),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        // 2a. Manual switch blocked
        await pickLine('预告备线');
        expect(p2.openedUris.last, endsWith('main10.mp4'));
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        // Dismiss picker and simulate playback failure -> auto-recovery MUST NOT open trailer.mp4!
        Navigator.of(tester.element(find.byType(PlayerEpisodePickerSheet))).pop();
        await tester.pumpAndSettle();
        p2.streamImpl.errorCtrl.add('Failed to open media');
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          p2.openedUris.any((u) => u.endsWith('trailer.mp4')),
          isFalse,
          reason: 'playback failure auto-recovery must never jump into trailer.mp4',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 450));

        // 3. Confirmed S02E10 + unique exact S02E10 (210) vs unseasoned E10 (110) -> binds 210!
        final s3 = await initTestStorage();
        final p3 = _Round3FakePlayer();
        final provider = DandanplayProvider(
          multilineServerUrls: origin,
          minRequestIntervalMs: 0,
          client: MockClient((req) async {
            if (req.url.path.contains('/comment/')) return http.Response('{"count":0,"comments":[]}', 200);
            if (req.url.path.contains('/search/')) return http.Response('{"animes":[]}', 200);
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'isMatched': false,
                  'matches': [
                    {'episodeId': 110, 'animeId': 1, 'animeTitle': '山中之花', 'episodeTitle': '第10集'},
                    {'episodeId': 210, 'animeId': 2, 'animeTitle': '山中之花 第二季', 'episodeTitle': 'S02E10'},
                  ],
                }),
              ),
              200,
            );
          }),
        );
        addTearDown(provider.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
            home: PlayerScreen(
              site: site,
              video: CmsVideo(
                id: 'movie',
                title: '山中之花',
                lines: [CmsLine(name: '主线', episodes: [mkMp4('S02E10', 'ten')])],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: s3,
              debugPlayer: p3,
              debugVideoSurface: const SizedBox.shrink(),
              debugDanmuProvider: provider,
              debugDanmuSettings: const DanmuSettings(enabled: true, serverUrls: origin),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        final boundId = tester
            .widget<DanmuLayer>(find.byType(DanmuLayer))
            .segmentCache
            ?.currentSession
            ?.boundEpisodeId;
        expect(boundId, DandanplayProvider.encodeBoundEpisodeId(origin, '210'));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 450));
      },
    );

    testWidgets(
      'WebDAV: dirty multiline editor rebases +M onto cloud [A,R], remote reorder preserved on local add/delete, and 409 MKCOL aborts when disabled (while working when enabled)',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const a = 'https://a.example';
        const b = 'https://b.example';
        const c = 'https://c.example';
        const l = 'https://local.example';
        const r = 'https://peer.example';
        const m = 'https://manual.example';

        DanmuSourceSyncDocument mkDoc(List<String> urls, int rev, int ts) =>
            DanmuSourceSyncDocument(
              initialized: true,
              revision: rev,
              updatedAt: ts,
              sources: [for (final u in urls) DanmuSyncSourceEntry(url: u)],
            );

        // 1. Dirty multiline editor: opened [A,B], typed +M, remote synced [A,R], Save & sync -> [A,R,M]!
        tester.view.physicalSize = const Size(1000, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final s1 = await initTestStorage();
        await s1.saveWebdavConfig(
          url: 'https://dav.example/dav/family/profile.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a, b], 1, 1),
          prefs: await SharedPreferences.getInstance(),
          pendingAuthOrigins: const <String>[],
        );
        var remote1 = mkDoc([a, r], 2, 200);
        final client1 = MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              remote1.toPayloadJson(),
              200,
              headers: {'etag': '"r${remote1.revision}"'},
            );
          }
          remote1 = DanmuSourceSyncDocument.tryParseJson(req.body)!;
          return http.Response('', 204);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmuSettingsSheet(
                key: const ValueKey('dirty-editor-rebase-sheet'),
                initialSettings: await DanmuPrefs.load(),
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('danmu-server-urls-field'));
        await tester.ensureVisible(field);
        await tester.enterText(field, '$a\n$b\n$m');
        await s1.syncWithWebdav(client: client1);
        await tester.pumpAndSettle();
        expect((await DanmuPrefs.load()).normalizedOrigins, [a, r]);
        final saveBtn = find.byKey(const Key('danmu-save-server-btn'));
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pumpAndSettle();
        await s1.syncWithWebdav(client: client1);
        await tester.pumpAndSettle();
        expect((await DanmuPrefs.load()).normalizedOrigins, [a, r, m]);
        expect(remote1.urls, [a, r, m]);

        // 2a. Remote reordered [B,A] while local only appended L -> [B,A,L]!
        final s2 = await initTestStorage();
        await s2.saveWebdavConfig(
          url: 'https://dav.example/dav/family/profile.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a, b], 1, 1),
          prefs: await SharedPreferences.getInstance(),
          pendingAuthOrigins: const <String>[],
        );
        await DanmuPrefs.save(const DanmuSettings(serverUrls: '$a\n$b\n$l'), nowMs: 200);
        var remote2 = mkDoc([b, a], 2, 100);
        final client2 = MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              remote2.toPayloadJson(),
              200,
              headers: {'etag': '"r${remote2.revision}"'},
            );
          }
          remote2 = DanmuSourceSyncDocument.tryParseJson(req.body)!;
          return http.Response('', 204);
        });
        await s2.syncWithWebdav(client: client2);
        expect(remote2.urls, [b, a, l]);

        // 2b. Remote reordered [B,A,C,R] while local deleted C during PUT -> {A,B,R,L} with B before A!
        final s3 = await initTestStorage();
        await s3.saveWebdavConfig(
          url: 'https://dav.example/dav/family/profile.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a, b, c], 1, 1),
          prefs: await SharedPreferences.getInstance(),
          pendingAuthOrigins: const <String>[],
        );
        await DanmuPrefs.save(const DanmuSettings(serverUrls: '$a\n$b\n$c\n$l'), nowMs: 100);
        var remote3 = mkDoc([b, a, c, r], 2, 200);
        final hold3 = Completer<void>();
        final rel3 = Completer<void>();
        int puts3 = 0;
        final client3 = MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              remote3.toPayloadJson(),
              200,
              headers: {'etag': '"r${remote3.revision}"'},
            );
          }
          puts3++;
          final inc = DanmuSourceSyncDocument.tryParseJson(req.body)!;
          if (puts3 == 1) {
            hold3.complete();
            await rel3.future;
          }
          remote3 = inc;
          return http.Response('', 204);
        });
        final run3 = s3.syncWithWebdav(client: client3);
        await hold3.future;
        await DanmuPrefs.save(const DanmuSettings(serverUrls: '$a\n$b\n$l'), nowMs: 300);
        rel3.complete();
        await run3;
        expect(remote3.urls.toSet(), {a, b, r, l});
        expect(remote3.urls.indexOf(b), lessThan(remote3.urls.indexOf(a)));

        // 3a. Switch off during first PUT -> 409 must NOT issue MKCOL or retry PUT!
        final s4 = await initTestStorage();
        await s4.saveWebdavConfig(
          url: 'https://dav.example/dav/family/profile.json',
          user: '',
          pass: '',
          auto: false,
          syncSubs: false,
          syncHistory: false,
          syncDanmu: true,
        );
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a], 1, 1),
          prefs: await SharedPreferences.getInstance(),
          pendingAuthOrigins: const <String>[],
        );
        final hold4 = Completer<void>();
        final rel4 = Completer<void>();
        final methodsOff = <String>[];
        int puts4 = 0;
        final client4 = MockClient((req) async {
          methodsOff.add(req.method);
          if (req.method == 'GET') return http.Response('', 404);
          if (req.method == 'MKCOL') return http.Response('', 201);
          puts4++;
          if (puts4 == 1) {
            hold4.complete();
            await rel4.future;
            return http.Response('', 409);
          }
          return http.Response('', 204);
        });
        final run4 = s4.syncWithWebdav(client: client4);
        await hold4.future;
        await s4.setWebdavSyncDanmu(false);
        rel4.complete();
        await expectLater(run4, throwsA(isA<FormatException>()));
        expect(methodsOff, ['GET', 'PUT']);

        // 3b. Positive control: switch stays ON -> 409 runs MKCOL and retry PUT succeeds!
        await s4.setWebdavSyncDanmu(true);
        final methodsOn = <String>[];
        int putsOn = 0;
        final clientOn = MockClient((req) async {
          methodsOn.add(req.method);
          if (req.method == 'GET') return http.Response('', 404);
          if (req.method == 'MKCOL') return http.Response('', 201);
          putsOn++;
          return http.Response('', putsOn == 1 ? 409 : 204);
        });
        final resOn = await s4.syncWithWebdav(client: clientOn);
        expect(resOn.danmuSynced, isTrue);
        expect(methodsOn, ['GET', 'PUT', 'MKCOL', 'MKCOL', 'PUT']);
      },
    );
  });

  // =========================================================================
  // POST-745b690 REWORK REGRESSIONS (Spinoff/Main Work Disambiguation,
  // Positional Head-Insert 3-Way Merge, and Manual-Hide 3-Frame Transition)
  // =========================================================================
  group('Post-745b690 Rework: Spinoff Guard, Head-Insert Sync Order & Manual HUD Hide Transition', () {
    testWidgets(
      'P1 Spinoff Guard: spinoff-only backup/danmu stays on main work & pending; mixed main+spinoff opens main file and binds 210 in BOTH candidate orders',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const origin = 'https://comments.example';
        const site = CmsSite(key: 'rev3', name: 'Rev3', type: 1, api: 'https://cdn.example/api');
        final tmp = Directory.systemTemp.createTempSync('marco_745b690_spinoff_');
        addTearDown(() => tmp.deleteSync(recursive: true));

        CmsEpisode mkMkv(String stem, String show) {
          final f = File('${tmp.path}/$stem.mkv')
            ..writeAsBytesSync(
              _buildMkvWithContainerTags(
                infoTitle: 'S02E10',
                simpleTags: {'SHOW': show, 'SEASON': '2', 'EPISODE': '10'},
              ),
            );
          return CmsEpisode(name: '$stem.mkv', url: f.path);
        }

        Future<void> pickLine(String target) async {
          await tester.tap(find.byKey(const Key('desktop-more-button')));
          await tester.pump(const Duration(milliseconds: 250));
          await tester.tap(find.text('切换线路'));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(find.textContaining(target).first);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
        }

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final mainEp = mkMkv('main-s02e10', '山中之花');
        final onlySpinoffEp = mkMkv('only-spinoff', '山中之花外传');
        final mainBackupEp = mkMkv('main-backup', '山中之花');

        // 1. Spinoff-only danmu (ID 910, both isMatched:false AND isMatched:true)
        //    AND spinoff-only backup line (`only-spinoff.mkv`):
        //    - Danmu MUST stay unbound (null / pending user selection), NOT 910.
        //    - Switching to spinoff-only backup MUST stay on main-s02e10.mkv & open picker.
        for (final serverIsMatched in const [false, true]) {
          final storage = await initTestStorage();
          final player = _Round3FakePlayer();
          final spinoffOnlyProvider = DandanplayProvider(
            multilineServerUrls: origin,
            minRequestIntervalMs: 0,
            client: MockClient((req) async {
              if (req.url.path.contains('/comment/')) {
                return http.Response('{"count":0,"comments":[]}', 200);
              }
              if (req.url.path.contains('/search/')) {
                return http.Response.bytes(
                  utf8.encode(
                    jsonEncode({
                      'animes': [
                        {
                          'animeId': 90,
                          'animeTitle': '山中之花外传',
                          'episodes': [
                            {'episodeId': 910, 'episodeTitle': 'S02E10'},
                          ],
                        },
                      ],
                    }),
                  ),
                  200,
                );
              }
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'isMatched': serverIsMatched,
                    'matches': [
                      {
                        'episodeId': 910,
                        'animeId': 90,
                        'animeTitle': '山中之花外传',
                        'episodeTitle': 'S02E10',
                      },
                    ],
                  }),
                ),
                200,
              );
            }),
          );
          addTearDown(spinoffOnlyProvider.close);

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
              home: PlayerScreen(
                site: site,
                video: CmsVideo(
                  id: 'movie_spinoff_only',
                  title: '山中之花',
                  lines: [
                    CmsLine(name: '主线', episodes: [mainEp]),
                    CmsLine(name: '仅外传备线', episodes: [onlySpinoffEp]),
                  ],
                ),
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                storage: storage,
                debugPlayer: player,
                debugVideoSurface: const SizedBox.shrink(),
                debugDanmuProvider: spinoffOnlyProvider,
                debugDanmuSettings: const DanmuSettings(enabled: true, serverUrls: origin),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));

          final boundBefore = tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId;
          expect(
            boundBefore,
            isNull,
            reason: 'isMatched=$serverIsMatched: spinoff ID 910 must NOT auto-bind for main work',
          );

          await pickLine('仅外传备线');
          expect(
            player.openedUris.last,
            endsWith('main-s02e10.mkv'),
            reason: 'isMatched=$serverIsMatched: spinoff-only backup must keep main-s02e10.mkv playing',
          );
          expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
          debugPrint(
            'P1_SPINOFF_ONLY(isMatched=$serverIsMatched): opened=${player.openedUris.last} bound=$boundBefore picker=true',
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 450));
        }

        // 2. Mixed main + spinoff in BOTH orders ([spinoff, main] AND [main, spinoff]):
        //    Both runs MUST open `main-backup.mkv` AND bind main danmu ID `210`!
        for (final reversed in const [false, true]) {
          final backupEps = reversed
              ? [mainBackupEp, onlySpinoffEp]
              : [onlySpinoffEp, mainBackupEp];
          final matchList = reversed
              ? [
                  {'episodeId': 210, 'animeId': 20, 'animeTitle': '山中之花', 'episodeTitle': 'S02E10'},
                  {'episodeId': 910, 'animeId': 90, 'animeTitle': '山中之花外传', 'episodeTitle': 'S02E10'},
                ]
              : [
                  {'episodeId': 910, 'animeId': 90, 'animeTitle': '山中之花外传', 'episodeTitle': 'S02E10'},
                  {'episodeId': 210, 'animeId': 20, 'animeTitle': '山中之花', 'episodeTitle': 'S02E10'},
                ];
          final storage = await initTestStorage();
          final player = _Round3FakePlayer();
          final mixedProvider = DandanplayProvider(
            multilineServerUrls: origin,
            minRequestIntervalMs: 0,
            client: MockClient((req) async {
              if (req.url.path.contains('/comment/')) {
                return http.Response('{"count":0,"comments":[]}', 200);
              }
              if (req.url.path.contains('/search/')) {
                return http.Response('{"animes":[]}', 200);
              }
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({'isMatched': false, 'matches': matchList}),
                ),
                200,
              );
            }),
          );
          addTearDown(mixedProvider.close);

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: Brightness.dark, platform: TargetPlatform.macOS),
              home: PlayerScreen(
                site: site,
                video: CmsVideo(
                  id: 'movie_mixed',
                  title: '山中之花',
                  lines: [
                    CmsLine(name: '主线', episodes: [mainEp]),
                    CmsLine(name: '混排备线', episodes: backupEps),
                  ],
                ),
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                storage: storage,
                debugPlayer: player,
                debugVideoSurface: const SizedBox.shrink(),
                debugDanmuProvider: mixedProvider,
                debugDanmuSettings: const DanmuSettings(enabled: true, serverUrls: origin),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));

          final expectedBound = DandanplayProvider.encodeBoundEpisodeId(origin, '210');
          final boundInitial = tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId;
          expect(boundInitial, expectedBound);

          await pickLine('混排备线');
          await tester.pump(const Duration(milliseconds: 450));
          final boundAfterSwitch = tester
              .widget<DanmuLayer>(find.byType(DanmuLayer))
              .segmentCache
              ?.currentSession
              ?.boundEpisodeId;
          expect(
            player.openedUris.last,
            endsWith('main-backup.mkv'),
            reason: 'reversed=$reversed must open main-backup.mkv instead of only-spinoff.mkv',
          );
          expect(
            boundAfterSwitch,
            expectedBound,
            reason: 'reversed=$reversed must bind main danmu ID 210 instead of 910',
          );
          debugPrint(
            'P1_MIXED(reversed=$reversed): opened=${player.openedUris.last} bound=$boundAfterSwitch',
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 450));
        }
      },
    );

    testWidgets(
      'P2 Head-Insert Sync Order: local [M,A,B] + peer [A,B,R] converges to [M,A,B,R] on both ends and stays stable after re-pull',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        const a = 'https://a.example';
        const b = 'https://b.example';
        const m = 'https://m-primary.example';
        const r = 'https://r-tail.example';

        DanmuSourceSyncDocument mkDoc(List<String> urls, int rev, int ts) =>
            DanmuSourceSyncDocument(
              initialized: true,
              revision: rev,
              updatedAt: ts,
              sources: [for (final u in urls) DanmuSyncSourceEntry(url: u)],
            );

        // 1. Direct 3-way merge symmetry check (both timestamp orders yield [M,A,B,R]).
        final baseDoc = mkDoc([a, b], 1, 100);
        for (final localNewer in const [false, true]) {
          final merged = DanmuSourceSyncMerger.merge(
            base: baseDoc,
            local: mkDoc([m, a, b], 2, localNewer ? 300 : 150),
            remote: mkDoc([a, b, r], 2, localNewer ? 150 : 300),
            hasLocalCredentials: false,
            nowMs: 400,
          );
          expect(
            merged.merged.urls,
            [m, a, b, r],
            reason: 'localNewer=$localNewer must keep M at head and R at tail',
          );
        }

        // 2. End-to-end UI dirty-editor + two-profile WebDAV sync + re-pull.
        tester.view.physicalSize = const Size(1000, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final sLocal = await initTestStorage();
        final peerPrefs = _IsolatedSharedPreferences();
        final sPeer = StorageService(peerPrefs);
        for (final s in [sLocal, sPeer]) {
          await s.saveWebdavConfig(
            url: 'https://dav.example/dav/family/profile.json',
            user: '',
            pass: '',
            auto: false,
            syncSubs: false,
            syncHistory: false,
            syncDanmu: true,
          );
        }
        final localPrefs = await SharedPreferences.getInstance();
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a, b], 1, 100),
          prefs: localPrefs,
          pendingAuthOrigins: const <String>[],
        );
        await DanmuPrefs.applySyncedDocument(
          mkDoc([a, b], 1, 100),
          prefs: peerPrefs,
          pendingAuthOrigins: const <String>[],
        );

        var cloudDoc = mkDoc([a, b], 1, 100);
        final client = MockClient((req) async {
          if (req.method == 'GET') {
            return http.Response(
              cloudDoc.toPayloadJson(),
              200,
              headers: {'etag': '"r${cloudDoc.revision}"'},
            );
          }
          if (req.method == 'PUT') {
            cloudDoc = DanmuSourceSyncDocument.tryParseJson(req.body)!;
            return http.Response('', 204);
          }
          return http.Response('', 201);
        });

        // Open DanmuSettingsSheet on local device with [A,B] and insert M at row 1 -> draft [M,A,B].
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmuSettingsSheet(
                key: const ValueKey('head-insert-merge-sheet'),
                initialSettings: await DanmuPrefs.load(),
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const Key('danmu-server-urls-field'));
        await tester.ensureVisible(field);
        await tester.enterText(field, '$m\n$a\n$b');

        // Peer appends R ([A,B,R]) and syncs to cloud; local pulls [A,B,R] while draft is unsaved.
        await DanmuPrefs.save(
          const DanmuSettings(serverUrls: '$a\n$b\n$r'),
          prefs: peerPrefs,
          nowMs: 200,
        );
        await sPeer.syncWithWebdav(client: client);
        expect(cloudDoc.urls, [a, b, r]);

        await sLocal.syncWithWebdav(client: client);
        await tester.pumpAndSettle();
        expect((await DanmuPrefs.load()).normalizedOrigins, [a, b, r]);

        // Local now clicks Save and syncs -> BOTH local and cloud MUST become [M,A,B,R]!
        final saveBtn = find.byKey(const Key('danmu-save-server-btn'));
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pumpAndSettle();
        await sLocal.syncWithWebdav(client: client);
        await tester.pumpAndSettle();

        expect((await DanmuPrefs.load()).normalizedOrigins, [m, a, b, r]);
        expect(cloudDoc.urls, [m, a, b, r]);

        // Peer pulls from cloud -> [M,A,B,R], and re-pulling on BOTH ends stays [M,A,B,R]!
        await sPeer.syncWithWebdav(client: client);
        expect((await DanmuPrefs.load(prefs: peerPrefs)).normalizedOrigins, [m, a, b, r]);

        await sLocal.syncWithWebdav(client: client);
        await sPeer.syncWithWebdav(client: client);
        final localFinal = (await DanmuPrefs.load()).normalizedOrigins;
        final peerFinal = (await DanmuPrefs.load(prefs: peerPrefs)).normalizedOrigins;
        expect(localFinal, [m, a, b, r]);
        expect(peerFinal, [m, a, b, r]);
        expect(cloudDoc.urls, [m, a, b, r]);
        debugPrint(
          'P2_HEAD_INSERT: local=$localFinal peer=$peerFinal cloud=${cloudDoc.urls}',
        );
      },
    );

    testWidgets(
      'P3 Manual Hide vs Auto-Hide on 900x600 ASS: start, mid, and end frames stay lifted until fade-out completes with zero bar overlap',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        final hasRealFont = artifactsDirPath.isNotEmpty
            ? (await tester.runAsync(_tryLoadVerificationSystemFont) ?? false)
            : false;
        tester.view.physicalSize = const Size(900, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        const winChannel = MethodChannel('window_manager');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(winChannel, (call) async {
          if (call.method == 'isFullScreen') return false;
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(winChannel, null);
        });

        final storage = await initTestStorage(
          initialPrefs: const <String, Object>{
            OnboardingPrefs.playHintDismissedKey: true,
            OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
            StorageService.keyDefaultAspectMode: 'contain',
          },
        );
        final player = _Round3FakePlayer();
        player.stateImpl.durationValue = const Duration(seconds: 5);
        addTearDown(player.dispose);

        final assTrack = SubtitleTrack(
          '2',
          '特效 ASS 字幕（顶部标识+底部双行）',
          'zh',
          codec: 'ass',
        );
        player.setActiveSubtitleTrack(
          assTrack,
          available: [SubtitleTrack.auto(), SubtitleTrack.no(), assTrack],
        );

        final videoFrameNotifier = ValueNotifier<ui.Image?>(null);
        addTearDown(() {
          videoFrameNotifier.value?.dispose();
          videoFrameNotifier.dispose();
        });

        String? loadedFrameName;
        Future<void> syncMpvFrameToCurrentSubPos() async {
          if (mpvFramesDirPath.isEmpty) return;
          final subPos = int.tryParse(player.platformImpl.properties['sub-pos'] ?? '100') ?? 100;
          final target = subPos < 100 ? 'mpv_ass_lifted_narrow.png' : 'mpv_ass_pos100.png';
          if (loadedFrameName == target) return;
          final f = File('$mpvFramesDirPath/$target');
          if (!f.existsSync()) return;
          final bytes = f.readAsBytesSync();
          final decoded = await tester.runAsync(() => decodeImageFromList(bytes));
          final prev = videoFrameNotifier.value;
          videoFrameNotifier.value = decoded;
          loadedFrameName = target;
          await tester.pump();
          prev?.dispose();
        }

        final boundaryKey = GlobalKey();
        final subDir = Directory.systemTemp.createTempSync('marco_p3_manual_');
        addTearDown(() => subDir.deleteSync(recursive: true));
        final dummyMkv = File('${subDir.path}/subtitle_verify.mkv')
          ..writeAsBytesSync(const [0, 1, 2, 3]);

        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                brightness: Brightness.dark,
                platform: TargetPlatform.macOS,
                fontFamily: hasRealFont ? 'VerifyFont' : null,
                useMaterial3: true,
              ),
              home: PlayerScreen(
                site: const CmsSite(
                  key: 'local_mkv',
                  name: '本地片源',
                  type: 1,
                  api: 'https://local.invalid/api',
                ),
                video: CmsVideo(
                  id: 'p3_manual_hide',
                  title: 'MKV 字幕手动收起对照',
                  lines: [
                    CmsLine(
                      name: 'MKV主线',
                      episodes: [
                        CmsEpisode(
                          name: 'S02E10 字幕实测',
                          url: Uri.file(dummyMkv.path).toString(),
                        ),
                      ],
                    ),
                  ],
                ),
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                storage: storage,
                debugPlayer: player,
                debugHudPrefs: PlayerHudPrefs.inMemory(isDesktop: true),
                debugOnboardingPrefs: OnboardingPrefs(
                  _IsolatedSharedPreferences(const <String, Object>{
                    OnboardingPrefs.playHintDismissedKey: true,
                    OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
                  }),
                ),
                debugDanmuSettings: const DanmuSettings(enabled: false),
                debugVideoSurface: ValueListenableBuilder<ui.Image?>(
                  valueListenable: videoFrameNotifier,
                  builder: (_, image, __) {
                    if (image != null) {
                      return ColoredBox(
                        color: Colors.black,
                        child: SizedBox.expand(
                          child: ClipRect(
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: RawImage(image: image),
                            ),
                          ),
                        ),
                      );
                    }
                    return const ColoredBox(color: Color(0xFF102030));
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        await syncMpvFrameToCurrentSubPos();

        double? readHudOpacity() {
          final hudFinder = find.byKey(const Key('player-hud-animated-visibility'));
          if (hudFinder.evaluate().isEmpty) return null;
          final fadeFinder = find.descendant(
            of: hudFinder,
            matching: find.byType(FadeTransition),
          );
          if (fadeFinder.evaluate().isEmpty) return null;
          return tester.widget<FadeTransition>(fadeFinder.first).opacity.value;
        }

        int readSubPos() =>
            int.tryParse(player.platformImpl.properties['sub-pos'] ?? '100') ?? 100;

        Future<void> captureFrame(String fileName) async {
          if (artifactsDirPath.isEmpty) return;
          await syncMpvFrameToCurrentSubPos();
          await _captureRepaintBoundaryPng(
            tester,
            boundaryKey,
            File('$artifactsDirPath/$fileName'),
          );
        }

        Future<Map<String, ({int subPos, double? opacity, bool hudMounted})>>
            sampleFadeOut(String label) async {
          ({int subPos, double? opacity, bool hudMounted})? startSnap;
          ({int subPos, double? opacity, bool hudMounted})? midSnap;
          ({int subPos, double? opacity, bool hudMounted})? endSnap;

          // Sample start (t=0ms) immediately when fade-out begins.
          final startOpacity = readHudOpacity();
          final startSubPos = readSubPos();
          final startMounted =
              find.byKey(const Key('desktop-player-hud')).evaluate().isNotEmpty;
          startSnap = (
            subPos: startSubPos,
            opacity: startOpacity,
            hudMounted: startMounted,
          );
          await captureFrame('subtitle_ass_narrow_900x600_${label}_1_start.png');

          expect(startMounted, isTrue, reason: '$label start: bottom HUD still visible');
          expect(startOpacity, closeTo(1.0, 0.05), reason: '$label start: HUD opacity ~1.0');
          expect(startSubPos, 89, reason: '$label start: ASS must stay lifted (sub-pos=89), not dropped!');

          var elapsed = 0;
          var overlapFrames = 0;
          while (elapsed < 320) {
            await tester.pump(const Duration(milliseconds: 16));
            elapsed += 16;
            final mounted =
                find.byKey(const Key('desktop-player-hud')).evaluate().isNotEmpty;
            final op = readHudOpacity();
            final sp = readSubPos();
            if (mounted && (op ?? 0.0) > 0.01 && sp >= 100) {
              overlapFrames++;
            }
            if (elapsed == 96) {
              midSnap = (subPos: sp, opacity: op, hudMounted: mounted);
              await captureFrame('subtitle_ass_narrow_900x600_${label}_2_mid.png');
              expect(mounted, isTrue, reason: '$label mid (96ms): HUD still fading');
              expect(op, isNotNull);
              expect(op!, greaterThan(0.05), reason: '$label mid (96ms): opacity > 0');
              expect(op, lessThan(0.95), reason: '$label mid (96ms): opacity < 1');
              expect(sp, 89, reason: '$label mid (96ms): ASS must stay lifted (sub-pos=89)');
            }
            if (elapsed == 240) {
              endSnap = (subPos: sp, opacity: op, hudMounted: mounted);
              await captureFrame('subtitle_ass_narrow_900x600_${label}_3_end.png');
              expect(mounted, isFalse, reason: '$label end (240ms): HUD unmounted');
              expect(sp, 100, reason: '$label end (240ms): ASS restored to baseline (100)');
            }
          }
          expect(overlapFrames, 0, reason: '$label must have 0 overlap frames across fade-out');
          return {'start': startSnap, 'mid': midSnap!, 'end': endSnap!};
        }

        // --- A. Manual Hide: click blank center of 900x600 window ---
        expect(find.byKey(const Key('desktop-player-hud')), findsOneWidget);
        expect(readSubPos(), 89);
        await tester.tapAt(const Offset(450, 260));
        // Advance exactly past the 260ms single-tap settlement window so
        // ToggleControlsEvent fires and starts manual fade-out on frame 1.
        await tester.pump(const Duration(milliseconds: 265));
        final manualTrace = await sampleFadeOut('manual');

        // Wake controls again with another blank tap, wait for full reveal.
        await tester.tapAt(const Offset(450, 260));
        await tester.pump(const Duration(milliseconds: 265));
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.byKey(const Key('desktop-player-hud')), findsOneWidget);
        expect(readSubPos(), 89);

        // --- B. Auto-Hide comparison: wait for 2200ms idle hide trigger ---
        // (240ms already elapsed since _scheduleHide(), so 1965ms triggers fade-out!)
        await tester.pump(const Duration(milliseconds: 1965));
        final autoTrace = await sampleFadeOut('auto');

        expect(manualTrace['start']!.subPos, autoTrace['start']!.subPos);
        expect(manualTrace['mid']!.subPos, autoTrace['mid']!.subPos);
        expect(manualTrace['end']!.subPos, autoTrace['end']!.subPos);
        debugPrint(
          'P3_TRANSITION_COMPARE: '
          'manual(start=${manualTrace['start']!.subPos}/${manualTrace['start']!.opacity?.toStringAsFixed(2)}, '
          'mid=${manualTrace['mid']!.subPos}/${manualTrace['mid']!.opacity?.toStringAsFixed(2)}, '
          'end=${manualTrace['end']!.subPos}/mounted=${manualTrace['end']!.hudMounted}) '
          'vs auto(start=${autoTrace['start']!.subPos}/${autoTrace['start']!.opacity?.toStringAsFixed(2)}, '
          'mid=${autoTrace['mid']!.subPos}/${autoTrace['mid']!.opacity?.toStringAsFixed(2)}, '
          'end=${autoTrace['end']!.subPos}/mounted=${autoTrace['end']!.hudMounted})',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 450));
      },
    );
  });
}

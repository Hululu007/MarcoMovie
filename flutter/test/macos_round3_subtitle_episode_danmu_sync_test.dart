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
import 'package:http/io_client.dart';
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
    });

    for (final viewportCase in const <({String label, Size size})>[
      (label: 'narrow_900x600', size: Size(900, 600)),
      (label: 'fullscreen_1440x900', size: Size(1440, 900)),
    ]) {
      testWidgets(
        'PlayerScreen lifts 2-line subtitle above bottom controls in ${viewportCase.label} for hidden/shown/dragging/slim-progress while keeping video, danmu & drag region stable',
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
        timeout: const Timeout(Duration(seconds: 15)),
        (tester) async {
          final hasRealFont = artifactsDirPath.isNotEmpty
              ? (await tester.runAsync(_tryLoadVerificationSystemFont) ?? false)
              : false;

          tester.view.physicalSize = viewportCase.size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final storage = await initTestStorage(
            initialPrefs: const <String, Object>{
              OnboardingPrefs.playHintDismissedKey: true,
              OnboardingPrefs.doneVersionKey: OnboardingPrefs.currentVersion,
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
          final videoFrameNotifier = ValueNotifier<Uint8List?>(null);
          addTearDown(videoFrameNotifier.dispose);

          Uint8List? loadMpvFrame(String name) {
            if (mpvFramesDirPath.isEmpty) return null;
            final f = File('$mpvFramesDirPath/$name');
            return f.existsSync() ? f.readAsBytesSync() : null;
          }

          videoFrameNotifier.value = loadMpvFrame('mpv_video_only.png');

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
                  debugVideoSurface: ValueListenableBuilder<Uint8List?>(
                    valueListenable: videoFrameNotifier,
                    builder: (_, bytes, __) {
                      if (bytes != null) {
                        return ColoredBox(
                          color: Colors.black,
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
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

          // --- Verify native libmpv ASS & PGS subtitle properties + real frame compositing ---
          final sizeTag = viewportCase.label.startsWith('narrow')
              ? 'narrow'
              : 'fullscreen';
          for (final nativeCase in <({
            String kind,
            SubtitleTrack track,
            String hiddenFrame,
            String liftedFrame,
          })>[
            (
              kind: 'ass',
              track: assTrack,
              hiddenFrame: 'mpv_ass_pos100.png',
              liftedFrame: 'mpv_ass_lifted_$sizeTag.png',
            ),
            (
              kind: 'pgs',
              track: pgsTrack,
              hiddenFrame: 'mpv_pgs_pos100.png',
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
            final liftedSubPos =
                int.tryParse(player.platformImpl.properties['sub-pos'] ?? '') ??
                    100;
            expect(
              liftedSubPos,
              lessThan(96),
              reason:
                  '${nativeCase.kind} in ${viewportCase.label} should lower sub-pos when HUD visible',
            );

            if (artifactsDirPath.isNotEmpty) {
              final liftedBytes = loadMpvFrame(nativeCase.liftedFrame);
              if (liftedBytes != null) {
                videoFrameNotifier.value = liftedBytes;
                await tester.pump(const Duration(milliseconds: 120));
                await _captureRepaintBoundaryPng(
                  tester,
                  boundaryKey,
                  File(
                    '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_2_shown.png',
                  ),
                );
                // Dragging progress with native track active (at same t=00:02)
                final g2 = await tester.startGesture(thumbAtTwoSec);
                await tester.pump(const Duration(milliseconds: 50));
                await g2.moveBy(const Offset(10, 0));
                await tester.pump(const Duration(milliseconds: 120));
                await _captureRepaintBoundaryPng(
                  tester,
                  boundaryKey,
                  File(
                    '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_3_dragging.png',
                  ),
                );
                await g2.up();
                await tester.pump(const Duration(milliseconds: 80));
              }
            }

            // Let HUD auto-hide -> sub-pos must restore to 100!
            await tester.pump(const Duration(milliseconds: 3600));
            await tester.pump(const Duration(milliseconds: 450));
            expect(controlsFinder, findsNothing);
            expect(player.platformImpl.properties['sub-pos'], '100');

            if (artifactsDirPath.isNotEmpty) {
              final hiddenBytes = loadMpvFrame(nativeCase.hiddenFrame);
              if (hiddenBytes != null) {
                videoFrameNotifier.value = hiddenBytes;
                await tester.pump(const Duration(milliseconds: 120));
                await _captureRepaintBoundaryPng(
                  tester,
                  boundaryKey,
                  File(
                    '$artifactsDirPath/subtitle_${nativeCase.kind}_${viewportCase.label}_1_hidden_slim.png',
                  ),
                );
              }
            }

            // Re-wake HUD for next track iteration
            await mouse.moveTo(
              Offset(viewportCase.size.width / 2 - 20, viewportCase.size.height / 2),
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
}

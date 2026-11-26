// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fvp/mdk.dart' as mdk;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/download_service.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/series_scraper.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/video_kernel.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:marco_movie/ui/poster_image.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:marco_movie/ui/windows_update_sheet.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'test_storage_helper.dart';

// ---------------------------------------------------------------------------
// Test Doubles
// ---------------------------------------------------------------------------

class _RecordingPlayerState extends Fake implements PlayerState {
  Playlist playlistValue = const Playlist([]);
  bool playingValue = false;
  bool completedValue = false;
  Duration positionValue = Duration.zero;
  Duration durationValue = const Duration(minutes: 45);
  double volumeValue = 100;
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

class _RecordingPlayerStream extends Fake implements PlayerStream {
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
  final volumeCtrl = StreamController<double>.broadcast();

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
      volumeCtrl.close(),
    ]);
  }
}

class _RecordingPlayer extends Fake implements Player {
  final _RecordingPlayerState _state = _RecordingPlayerState();
  final _RecordingPlayerStream _stream = _RecordingPlayerStream();
  final List<({String uri, int startMs})> opened = [];
  final Future<void> Function(_RecordingPlayer self, Media media)? onOpen;
  bool disposed = false;

  _RecordingPlayer({this.onOpen});

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  PlayerStream get stream => _stream;

  void emitError(String message) {
    if (!disposed) _stream.errorCtrl.add(message);
  }

  void emitPosition(Duration pos) {
    _state.positionValue = pos;
    if (!disposed) _stream.positionCtrl.add(pos);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) {
      opened.add(
        (uri: playable.uri, startMs: playable.start?.inMilliseconds ?? 0),
      );
      _state.playlistValue = Playlist([playable]);
      if (onOpen != null) {
        await onOpen!(this, playable);
        return;
      }
      _state.durationValue = const Duration(minutes: 45);
      _state.positionValue = playable.start ?? const Duration(milliseconds: 500);
      _state.playingValue = play;
      _state.bufferingValue = false;
      if (!disposed) {
        _stream.durationCtrl.add(_state.durationValue);
        _stream.positionCtrl.add(_state.positionValue);
        _stream.bufferingCtrl.add(false);
        _stream.playingCtrl.add(play);
      }
    }
  }

  @override
  Future<void> stop() async => _state.playingValue = false;
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
  Future<void> seek(Duration duration) async {
    _state.positionValue = duration;
    if (!disposed) _stream.positionCtrl.add(duration);
  }

  @override
  Future<void> setRate(double rate) async => _state.rateValue = rate;
  @override
  Future<void> setVolume(double volume) async => _state.volumeValue = volume;
  @override
  Future<void> setAudioTrack(AudioTrack track) async {}
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await _stream.close();
  }
}

class _ControllableMdkBackend implements MdkNativeBackend {
  final ValueNotifier<int?> _textureId = ValueNotifier<int?>(null);
  final _statusCtrl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final _stateCtrl = StreamController<mdk.PlaybackState>.broadcast();
  final _eventCtrl =
      StreamController<({int error, String category, String detail})>.broadcast();

  final List<({String media, int position})> prepareCalls = [];
  Future<int> Function(String media, int position)? onPrepare;
  String _media = '';
  int _positionMs = 0;
  int _bufferedMs = 0;
  final bool _isLive = false;
  bool disposed = false;

  MdkMediaSnapshot snapshot = const MdkMediaSnapshot(
    durationMs: 2700000,
    videoWidth: 1920,
    videoHeight: 1080,
  );

  @override
  ValueListenable<int?> get textureIdListenable => _textureId;
  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged =>
      _statusCtrl.stream;
  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtrl.stream;
  @override
  Stream<({int error, String category, String detail})> get onEvent =>
      _eventCtrl.stream;
  @override
  int get positionMs => _positionMs;
  @override
  int get bufferedMs => _bufferedMs;
  @override
  bool get isLive => _isLive;
  @override
  MdkMediaSnapshot readMediaSnapshot() => snapshot;

  @override
  set media(String uri) => _media = uri;
  String get media => _media;
  @override
  set state(mdk.PlaybackState value) {
    if (!_stateCtrl.isClosed) _stateCtrl.add(value);
  }

  @override
  set playbackRate(double value) {}
  @override
  set volume(double value) {}
  @override
  set mute(bool value) {}
  @override
  set loop(int value) {}
  @override
  set videoDecoders(List<String> decoders) {}
  @override
  set activeAudioTracks(List<int> tracks) {}
  @override
  set activeSubtitleTracks(List<int> tracks) {}
  @override
  set activeVideoTracks(List<int> tracks) {}
  @override
  void setProperty(String key, String value) {}
  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {}
  @override
  void setMediaForType(String uri, mdk.MediaType type) {}

  @override
  Future<int> prepare({int position = 0}) async {
    _positionMs = position;
    prepareCalls.add((media: _media, position: position));
    if (onPrepare != null) {
      return onPrepare!(_media, position);
    }
    return 0;
  }

  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) async {
    _positionMs = position;
    return position;
  }

  @override
  Future<int> updateTexture({int? width, int? height}) async {
    _textureId.value = 42;
    return 42;
  }

  void emitEvent({
    required int error,
    required String category,
    String detail = '',
  }) {
    if (!_eventCtrl.isClosed) {
      _eventCtrl.add((error: error, category: category, detail: detail));
    }
  }

  void emitStatus(int oldStatus, int newStatus) {
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add((oldStatus: oldStatus, newStatus: newStatus));
    }
  }

  @override
  Future<void> disposeAsync() async {
    disposed = true;
    await _statusCtrl.close();
    await _stateCtrl.close();
    await _eventCtrl.close();
    _textureId.dispose();
  }
}

class _StubClient extends CmsClient {
  final List<LiveGroup> groups;
  _StubClient({this.groups = const []});

  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async =>
      (const <CmsCategory>[], const CmsListing(videos: <CmsVideo>[]));

  @override
  Future<List<LiveGroup>> fetchLiveGroups(LiveSource source) async => groups;
}

class _RealHttpOverrides extends HttpOverrides {}

class _ConfigurablePathProvider extends PathProviderPlatform {
  final Directory root;
  final Duration downloadsDelay;
  final bool failDownloads;
  _ConfigurablePathProvider(
    this.root, {
    this.downloadsDelay = Duration.zero,
    this.failDownloads = false,
  });

  @override
  Future<String?> getDownloadsPath() async {
    if (downloadsDelay > Duration.zero) {
      await Future<void>.delayed(downloadsDelay);
    }
    if (failDownloads) {
      throw const FileSystemException('Simulated disconnected downloads drive');
    }
    return '${root.path}/downloads';
  }

  @override
  Future<String?> getApplicationSupportPath() async => '${root.path}/support';

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${root.path}/documents';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  // =========================================================================
  // P1A: Cross-Line Episode Matching & Progress Preservation
  // =========================================================================
  group('P1A: Cross-line episode matching & progress preservation', () {
    test('SeriesScraper.matchEpisodeAcrossLines covers preview, reverse, cross-season, bonus & ambiguity', () {
      const lineA = CmsLine(name: 'A', episodes: [
        CmsEpisode(name: '第01集', url: 'file:///a01.mp4'),
        CmsEpisode(name: '第02集', url: 'file:///a02.mp4'),
      ]);
      const lineBPreview = CmsLine(name: 'B', episodes: [
        CmsEpisode(name: '预告', url: 'file:///b_pv.mp4'),
        CmsEpisode(name: '第01集', url: 'file:///b01.mp4'),
        CmsEpisode(name: '第02集', url: 'file:///b02.mp4'),
      ]);

      // 1. Leading preview
      final mPreview = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineA,
        fromEpisodeIndex: 1,
        targetLine: lineBPreview,
        seriesTitle: '测试剧集',
      );
      expect(mPreview.isMatched, isTrue);
      expect(mPreview.episodeIndex, 2);
      expect(
        SeriesScraper.isSameEpisodeAcrossLines(
          fromLine: lineA,
          fromEpisodeIndex: 1,
          targetLine: lineBPreview,
          targetEpisodeIndex: 2,
          seriesTitle: '测试剧集',
        ),
        isTrue,
      );
      // Same index 1 in B is 第01集, NOT 第02集
      expect(
        SeriesScraper.isSameEpisodeAcrossLines(
          fromLine: lineA,
          fromEpisodeIndex: 1,
          targetLine: lineBPreview,
          targetEpisodeIndex: 1,
          seriesTitle: '测试剧集',
        ),
        isFalse,
      );

      // 2. Reversed order (Tv063OptimizationChecks style)
      const lineAsc = CmsLine(name: '线路A', episodes: [
        CmsEpisode(name: '第01集', url: 'file:///a1.mp4'),
        CmsEpisode(name: '第05集', url: 'file:///a5.mp4'),
      ]);
      const lineRev = CmsLine(name: '夸克4K', episodes: [
        CmsEpisode(name: 'Show.S01E05.2160p.mkv', url: 'file:///b5.mp4'),
        CmsEpisode(name: 'Show.S01E01.2160p.mkv', url: 'file:///b1.mp4'),
      ]);
      final mRev = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineAsc,
        fromEpisodeIndex: 1,
        targetLine: lineRev,
        seriesTitle: 'Show',
      );
      expect(mRev.isMatched, isTrue);
      expect(mRev.episodeIndex, 0);

      // 3. Cross-season same episode number
      const multiSeasonA = CmsLine(name: '多季A', episodes: [
        CmsEpisode(name: 'S01E02', url: 'file:///a_s1e2.mp4'),
        CmsEpisode(name: 'S02E02', url: 'file:///a_s2e2.mp4'),
      ]);
      const multiSeasonB = CmsLine(name: '多季B', episodes: [
        CmsEpisode(name: 'S02E02', url: 'file:///b_s2e2.mp4'),
        CmsEpisode(name: 'S01E02', url: 'file:///b_s1e2.mp4'),
      ]);
      final mSeasonExact = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: multiSeasonA,
        fromEpisodeIndex: 1, // S02E02
        targetLine: multiSeasonB,
        seriesTitle: '测试剧集',
      );
      expect(mSeasonExact.isMatched, isTrue);
      expect(mSeasonExact.episodeIndex, 0);

      // S02E02 vs S01-only line -> MUST NOT match S01E02
      const season1Only = CmsLine(name: '仅第一季', episodes: [
        CmsEpisode(name: 'S01E01', url: 'file:///s1e1.mp4'),
        CmsEpisode(name: 'S01E02', url: 'file:///s1e2.mp4'),
      ]);
      final mSeasonConflict = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: multiSeasonA,
        fromEpisodeIndex: 1, // S02E02
        targetLine: season1Only,
        seriesTitle: '测试剧集',
      );
      expect(mSeasonConflict.isMatched, isFalse);

      // Unseasoned 第02集 vs multi-season [S01E02, S02E02] -> ambiguous!
      final mSeasonAmbiguous = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineA,
        fromEpisodeIndex: 1, // 第02集
        targetLine: multiSeasonB,
        seriesTitle: '测试剧集',
      );
      expect(mSeasonAmbiguous.kind, CrossLineEpisodeMatchKind.ambiguous);

      // 4. Main episode vs bonus/special (正片与特典)
      const lineWithBonus = CmsLine(name: '含特典线', episodes: [
        CmsEpisode(name: '特典01', url: 'file:///b_sp1.mp4'),
        CmsEpisode(name: '第01集', url: 'file:///b_ep1.mp4'),
        CmsEpisode(name: '特典02', url: 'file:///b_sp2.mp4'),
        CmsEpisode(name: '第02集', url: 'file:///b_ep2.mp4'),
      ]);
      final mMainAvoidsBonus = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineA,
        fromEpisodeIndex: 0, // 第01集
        targetLine: lineWithBonus,
        seriesTitle: '测试剧集',
      );
      expect(mMainAvoidsBonus.isMatched, isTrue);
      expect(mMainAvoidsBonus.episodeIndex, 1); // b_ep1, NOT 特典01

      // Bonus switching to main-only line -> unmatched (never jumps to 第01集)
      final mBonusToMain = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineWithBonus,
        fromEpisodeIndex: 0, // 特典01
        targetLine: lineA,
        seriesTitle: '测试剧集',
      );
      expect(mBonusToMain.isMatched, isFalse);

      // Bonus switching to another line with matching bonus -> matched
      const lineBonusAlt = CmsLine(name: '特典备线', episodes: [
        CmsEpisode(name: '第01集', url: 'file:///c_ep1.mp4'),
        CmsEpisode(name: 'Bonus 01', url: 'file:///c_sp1.mp4'),
      ]);
      final mBonusToBonus = SeriesScraper.matchEpisodeAcrossLines(
        fromLine: lineWithBonus,
        fromEpisodeIndex: 0, // 特典01
        targetLine: lineBonusAlt,
        seriesTitle: '测试剧集',
      );
      expect(mBonusToBonus.isMatched, isTrue);
      expect(mBonusToBonus.episodeIndex, 1);
    });

    testWidgets(
      'P1A PlayerScreen: A02 at 12:34 -> switch line to B ([预告, 第01集, 第02集]) opens b02.mp4 at 754000ms; episode picker checks identity not index; unmatched opens picker',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = await initTestStorage();
        final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
        addTearDown(hudPrefs.dispose);
        final appearance = WindowsAppearance(Directory.systemTemp);
        addTearDown(appearance.dispose);
        final player = _RecordingPlayer();
        addTearDown(player.dispose);

        const site = CmsSite(
          key: 's1',
          name: 'Test',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const video = CmsVideo(
          id: 'v1',
          title: '测试剧集',
          lines: [
            CmsLine(name: '线路A', episodes: [
              CmsEpisode(name: '第01集', url: 'file:///fixture/a01.mp4'),
              CmsEpisode(name: '第02集', url: 'file:///fixture/a02.mp4'),
            ]),
            CmsLine(name: '线路B', episodes: [
              CmsEpisode(name: '预告', url: 'file:///fixture/b_pv.mp4'),
              CmsEpisode(name: '第01集', url: 'file:///fixture/b01.mp4'),
              CmsEpisode(name: '第02集', url: 'file:///fixture/b02.mp4'),
            ]),
            CmsLine(name: '线路C倒序', episodes: [
              CmsEpisode(name: 'Show.S01E02.4K.mkv', url: 'file:///fixture/c02.mp4'),
              CmsEpisode(name: 'Show.S01E01.4K.mkv', url: 'file:///fixture/c01.mp4'),
            ]),
            CmsLine(name: '线路D跨季', episodes: [
              CmsEpisode(name: 'S01E02', url: 'file:///fixture/d_s1e2.mp4'),
              CmsEpisode(name: 'S02E02', url: 'file:///fixture/d_s2e2.mp4'),
            ]),
            CmsLine(name: '线路E仅特典', episodes: [
              CmsEpisode(name: '特典01', url: 'file:///fixture/e_sp1.mp4'),
              CmsEpisode(name: '特典02', url: 'file:///fixture/e_sp2.mp4'),
            ]),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 1,
              initialPositionMs: 754000,
              storage: storage,
              debugPlayer: player,
              debugHudPrefs: hudPrefs,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await player.seek(const Duration(milliseconds: 754000));
        await tester.pump(const Duration(milliseconds: 200));

        // 1. More -> Switch Line -> Line B (leading preview): MUST open b02.mp4 at 754000ms
        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换线路'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路B'));
        await tester.pump(const Duration(milliseconds: 650));

        final afterSwitchB = player.opened.last;
        debugPrint(
          'EVIDENCE_1_LINE_SWITCH: uri=${afterSwitchB.uri}, startMs=${afterSwitchB.startMs}',
        );
        expect(afterSwitchB.uri, endsWith('b02.mp4'));
        expect(afterSwitchB.startMs, 754000);

        // 2. Switch Line from Line B (unseasoned 第02集) -> Line D (cross-season ambiguous [S01E02, S02E02]):
        // MUST NOT blindly switch; MUST open episode picker for user selection!
        final countBeforeAmbiguous = player.opened.length;
        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换线路'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路D跨季'));
        await tester.pumpAndSettle();
        expect(player.opened.length, countBeforeAmbiguous);
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        // Close picker by choosing S02E02 manually -> unverified season match -> 0ms!
        await tester.tap(find.text('S02E02'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('d_s2e2.mp4'));
        expect(player.opened.last.startMs, 0);

        // 3. Switch back to Line B 第02集 at 754000ms, then Switch Line -> Line C (reversed):
        // MUST open c02.mp4 (Show.S01E02.4K.mkv) at 754000ms!
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路B (3)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 2 集'));
        await tester.pump(const Duration(milliseconds: 650));
        await player.seek(const Duration(milliseconds: 754000));
        await tester.pump(const Duration(milliseconds: 200));

        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换线路'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路C倒序'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('c02.mp4'));
        expect(player.opened.last.startMs, 754000);

        // 3b. From Line C (explicit S01E02) -> Line D ([S01E02, S02E02]):
        // Explicit season S01 uniquely matches d_s1e2.mp4 and preserves 754000ms!
        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换线路'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路D跨季'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('d_s1e2.mp4'));
        expect(player.opened.last.startMs, 754000);

        // 4. Switch Line -> Line E (only bonus [特典01, 特典02]):
        // MUST NOT jump to 特典02; MUST open episode picker!
        await player.seek(const Duration(milliseconds: 300000));
        await tester.pump(const Duration(milliseconds: 200));
        final countBeforeBonus = player.opened.length;
        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换线路'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路E仅特典'));
        await tester.pumpAndSettle();
        expect(player.opened.length, countBeforeBonus);
        expect(find.byType(PlayerEpisodePickerSheet), findsOneWidget);
        // Pick Line A 第02集 from multi-season Line D (S01E02) -> multi-season vs unseasoned -> 0ms
        await tester.tap(find.text('线路A (2)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 2 集'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('a02.mp4'));
        expect(player.opened.last.startMs, 0);

        // 5. Episodes sheet: playing A02 (idx 1) at 500000ms:
        //    5a) Pick B[2] (第02集, different idx, SAME episode) -> inherits 500000ms!
        await player.seek(const Duration(milliseconds: 500000));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路B (3)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 2 集'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('b02.mp4'));
        expect(player.opened.last.startMs, 500000);

        //    5b) Playing B[2] (第02集) at 500000ms, pick A[0] or B[1] (第01集, manual different episode) -> 0ms!
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 1 集'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('b01.mp4'));
        expect(player.opened.last.startMs, 0);

        //    5c) Playing A[1] (第02集) at 420000ms, pick B[1] (第01集, SAME array index 1, DIFFERENT episode) -> 0ms!
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路A (2)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 2 集'));
        await tester.pump(const Duration(milliseconds: 650));
        await player.seek(const Duration(milliseconds: 420000));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('选集'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('线路B (3)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 1 集'));
        await tester.pump(const Duration(milliseconds: 650));
        expect(player.opened.last.uri, endsWith('b01.mp4'));
        expect(player.opened.last.startMs, 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 700));
      },
    );
  });

  // =========================================================================
  // P1B: MDK Error Propagation & Resume-Failure MPV Fallback
  // =========================================================================
  group('P1B: MDK error stream & MPV automatic fallback', () {
    test(
      'MdkPlatformPlayer emits both decoder.video negative error (with detail) and reader.open error without clobbering activeVideoDecoderName',
      () async {
        final backend = _ControllableMdkBackend();
        final mdkPlayer = MdkPlatformPlayer(debugBackend: backend);
        addTearDown(mdkPlayer.dispose);

        final errors = <String>[];
        final sub = mdkPlayer.stream.error.listen(errors.add);
        addTearDown(sub.cancel);

        backend.emitEvent(
          error: 0,
          category: 'decoder.video',
          detail: 'MFT:d3d=11',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(mdkPlayer.activeVideoDecoderName, 'MFT:d3d=11');
        expect(errors, isEmpty);

        backend.emitEvent(
          error: -1,
          category: 'decoder.video',
          detail: 'D3D11 init failed',
        );
        backend.emitEvent(
          error: -2,
          category: 'reader.open',
          detail: '404 Not Found',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(errors.length, 2);
        expect(errors[0], contains('MDK decoder.video: D3D11 init failed (-1)'));
        expect(errors[1], contains('MDK reader.open: 404 Not Found (-2)'));
        expect(mdkPlayer.activeVideoDecoderName, 'MFT:d3d=11');
      },
    );

    test(
      'MdkPlatformPlayer ignores demuxer read-ahead EOF during mid-video seek and completes at actual end',
      () async {
        final backend = _ControllableMdkBackend()
          ..snapshot = const MdkMediaSnapshot(
            durationMs: 18023,
            videoWidth: 1280,
            videoHeight: 720,
          );
        final mdkPlayer = MdkPlatformPlayer(debugBackend: backend);
        addTearDown(mdkPlayer.dispose);

        await mdkPlayer.open(Media('file:///mdk/sample_18s.mkv'), play: true);
        await mdkPlayer.seek(const Duration(seconds: 8));
        backend._positionMs = 8000;
        backend._bufferedMs = 10023;
        backend.emitStatus(
          mdk.MediaStatus.loaded | mdk.MediaStatus.buffered,
          mdk.MediaStatus.loaded | mdk.MediaStatus.buffered | mdk.MediaStatus.end,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(mdkPlayer.state.completed, isFalse);
        expect(mdkPlayer.state.playing, isTrue);

        // Once clock reaches the actual end with empty remaining buffer, completion fires.
        backend._positionMs = 17900;
        backend._bufferedMs = 0;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(mdkPlayer.state.completed, isTrue);
        expect(mdkPlayer.state.playing, isFalse);
      },
    );

    testWidgets(
      'MDK fallback covers zero-start, 12:34 breakpoint resume, duplicate errors, late stale error after episode switch, and preserves saved default MDK engine',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const site = CmsSite(
          key: 's_mdk',
          name: 'Test',
          type: 1,
          api: 'https://owned.invalid/api',
        );
        const video = CmsVideo(
          id: 'v_mdk',
          title: 'MDK 回退测试',
          lines: [
            CmsLine(name: '主线', episodes: [
              CmsEpisode(name: '第01集', url: 'file:///mdk/ep01.mp4'),
              CmsEpisode(name: '第02集', url: 'file:///mdk/ep02.mp4'),
            ]),
          ],
        );

        // --- Subcase 1: Zero progress fallback ---
        {
          final storage = await initTestStorage();
          await storage.setWindowsPlaybackEngine('mdk');
          final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
          addTearDown(hudPrefs.dispose);
          final appearance = WindowsAppearance(Directory.systemTemp);
          addTearDown(appearance.dispose);

          final mdkBackend = _ControllableMdkBackend();
          final mpvPlayer = _RecordingPlayer();
          var fallbackCreations = 0;

          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) =>
                  WindowsAppearanceScope(controller: appearance, child: child!),
              home: PlayerScreen(
                site: site,
                video: video,
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                initialPositionMs: 0,
                storage: storage,
                debugHudPrefs: hudPrefs,
                debugVideoSurface: const ColoredBox(color: Colors.black),
                debugWindowsKernelFactory: (engine) {
                  if (engine == WindowsPlaybackEngine.mdk) {
                    return VideoKernel.create(
                      hwdec: 'auto-safe',
                      windowsEngine: WindowsPlaybackEngine.mdk,
                      debugMdkBackend: mdkBackend,
                      debugVideoSurface: const ColoredBox(color: Colors.black),
                    );
                  }
                  fallbackCreations++;
                  return VideoKernel.create(
                    debugPlayer: mpvPlayer,
                    hwdec: 'auto-safe',
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  );
                },
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));

          mdkBackend.emitEvent(
            error: -1,
            category: 'decoder.video',
            detail: 'MFT unsupported profile',
          );
          for (var i = 0; i < 8 && mpvPlayer.opened.isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }

          expect(fallbackCreations, 1);
          expect(mpvPlayer.opened.length, 1);
          expect(mpvPlayer.opened.single.uri, endsWith('ep01.mp4'));
          expect(mpvPlayer.opened.single.startMs, 0);
          expect(storage.windowsPlaybackEngine, 'mdk');

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 700));
        }

        // --- Subcase 2 & 3: Breakpoint resume (12:34 = 754000ms) + Duplicate errors ---
        {
          final storage = await initTestStorage();
          await storage.setWindowsPlaybackEngine('mdk');
          final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
          addTearDown(hudPrefs.dispose);
          final appearance = WindowsAppearance(Directory.systemTemp);
          addTearDown(appearance.dispose);

          final mdkBackend = _ControllableMdkBackend();
          final mpvPlayer = _RecordingPlayer();
          var fallbackCreations = 0;

          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) =>
                  WindowsAppearanceScope(controller: appearance, child: child!),
              home: PlayerScreen(
                site: site,
                video: video,
                initialLineIndex: 0,
                initialEpisodeIndex: 1,
                initialPositionMs: 754000,
                storage: storage,
                debugHudPrefs: hudPrefs,
                debugVideoSurface: const ColoredBox(color: Colors.black),
                debugWindowsKernelFactory: (engine) {
                  if (engine == WindowsPlaybackEngine.mdk) {
                    return VideoKernel.create(
                      hwdec: 'auto-safe',
                      windowsEngine: WindowsPlaybackEngine.mdk,
                      debugMdkBackend: mdkBackend,
                      debugVideoSurface: const ColoredBox(color: Colors.black),
                    );
                  }
                  fallbackCreations++;
                  return VideoKernel.create(
                    debugPlayer: mpvPlayer,
                    hwdec: 'auto-safe',
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  );
                },
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));

          // Burst of 3 duplicate errors right after container open at 12:34
          mdkBackend.emitEvent(
            error: -1,
            category: 'decoder.video',
            detail: 'D3D11 HEVC 10bit decode failed',
          );
          mdkBackend.emitEvent(
            error: -2,
            category: 'reader.open',
            detail: 'Stream decoder aborted',
          );
          mdkBackend.emitStatus(
            mdk.MediaStatus.loaded,
            mdk.MediaStatus.invalid,
          );
          for (var i = 0; i < 10; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }

          debugPrint(
            'EVIDENCE_2_MDK_FALLBACK: count=$fallbackCreations, '
            'mpvOpens=${mpvPlayer.opened}, savedDefault=${storage.windowsPlaybackEngine}',
          );
          expect(fallbackCreations, 1);
          expect(mpvPlayer.opened.length, 1);
          expect(mpvPlayer.opened.single.uri, endsWith('ep02.mp4'));
          expect(mpvPlayer.opened.single.startMs, 754000);
          expect(storage.windowsPlaybackEngine, 'mdk');

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 700));
        }

        // --- Subcase 4: Late stale error from Ep 1 arriving after switching to Ep 2 ---
        {
          final storage = await initTestStorage();
          await storage.setWindowsPlaybackEngine('mdk');
          final hudPrefs = PlayerHudPrefs.inMemory(isDesktop: true);
          addTearDown(hudPrefs.dispose);
          final appearance = WindowsAppearance(Directory.systemTemp);
          addTearDown(appearance.dispose);

          final ep1Prepare = Completer<int>();
          final mdkBackend = _ControllableMdkBackend()
            ..onPrepare = (media, pos) {
              if (media.endsWith('ep01.mp4')) return ep1Prepare.future;
              return Future<int>.value(0);
            };
          var fallbackCreations = 0;

          await tester.pumpWidget(
            MaterialApp(
              builder: (_, child) =>
                  WindowsAppearanceScope(controller: appearance, child: child!),
              home: PlayerScreen(
                site: site,
                video: video,
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                initialPositionMs: 0,
                storage: storage,
                debugHudPrefs: hudPrefs,
                debugVideoSurface: const ColoredBox(color: Colors.black),
                debugWindowsKernelFactory: (engine) {
                  if (engine == WindowsPlaybackEngine.mdk) {
                    return VideoKernel.create(
                      hwdec: 'auto-safe',
                      windowsEngine: WindowsPlaybackEngine.mdk,
                      debugMdkBackend: mdkBackend,
                      debugVideoSurface: const ColoredBox(color: Colors.black),
                    );
                  }
                  fallbackCreations++;
                  return VideoKernel.create(
                    debugPlayer: _RecordingPlayer(),
                    hwdec: 'auto-safe',
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  );
                },
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));

          // Switch to Ep 2 while Ep 1 prepare is still pending
          await tester.tap(find.text('选集'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('第 2 集'));
          await tester.pump(const Duration(milliseconds: 300));

          // Now Ep 1's stale prepare fails late!
          ep1Prepare.complete(-1);
          await tester.pump(const Duration(milliseconds: 300));

          expect(fallbackCreations, 0);
          expect(mdkBackend.media, endsWith('ep02.mp4'));
          expect(storage.windowsPlaybackEngine, 'mdk');

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 700));
        }
      },
    );
  });

  // =========================================================================
  // P2A: Windows Update Flow, Distribution Routing & Verification
  // =========================================================================
  group('P2A: Windows update version states, installer vs portable routing, retry & verification', () {
    test('WindowsInstallDetector distinguishes installed vs portable by running EXE path when both exist', () async {
      final root = Directory.systemTemp.createTempSync('marco-win-dist-test-');
      addTearDown(() => root.deleteSync(recursive: true));

      final installedDir = Directory('${root.path}/Installed/Marco Movie')
        ..createSync(recursive: true);
      File('${installedDir.path}/marco_movie.exe').writeAsStringSync('exe');
      File('${installedDir.path}/unins000.exe').writeAsStringSync('unins');
      File('${installedDir.path}/unins000.dat')
          .writeAsStringSync('Inno Setup Uninstall Log Marco Movie marco_movie.exe');

      final portableDir = Directory('${root.path}/Portable/MarcoMovie')
        ..createSync(recursive: true);
      File('${portableDir.path}/marco_movie.exe').writeAsStringSync('exe');

      // Both exist on the same PC, and registry points to installedDir
      final registered = <String>[installedDir.path];

      final fromInstalled = await WindowsInstallDetector.detect(
        executablePath: '${installedDir.path}/marco_movie.exe',
        registeredInstallLocations: registered,
      );
      expect(fromInstalled.distribution, WindowsDistributionKind.installer);
      expect(fromInstalled.isInstaller, isTrue);
      expect(
        WindowsInstallDetector.normalizeWindowsDir(fromInstalled.installDirectory),
        WindowsInstallDetector.normalizeWindowsDir(installedDir.path),
      );

      final fromPortable = await WindowsInstallDetector.detect(
        executablePath: '${portableDir.path}/marco_movie.exe',
        registeredInstallLocations: registered,
      );
      expect(fromPortable.distribution, WindowsDistributionKind.portable);
      expect(fromPortable.isPortable, isTrue);
      expect(fromPortable.matchedRegisteredInstall, isFalse);
      expect(fromPortable.hasLocalUninstaller, isFalse);
    });

    test('AppUpdate.parse extracts both setup exe and portable zip and downloads/verifies/cleans staging', () async {
      final setupBytes = utf8.encode('SETUP_INSTALLER_PAYLOAD_072');
      final setupSha = sha256.convert(setupBytes).toString();
      final portableBytes = utf8.encode('PORTABLE_ZIP_PAYLOAD_072_VERIFIED');
      final portableSha = sha256.convert(portableBytes).toString();

      final manifest = <String, dynamic>{
        'schema': 1,
        'platform': 'windows',
        'versionName': '0.7.2',
        'notes': 'Windows 0.7.2 优化更新',
        'packages': {
          'MarcoMovie-0.7.2-windows-x64-setup.exe': {
            'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.7.2-windows-x64-setup.exe',
            'sha256': setupSha,
            'size': setupBytes.length,
          },
          'MarcoMovie-0.7.2-windows-x64-portable.zip': {
            'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.7.2-windows-x64-portable.zip',
            'sha256': portableSha,
            'size': portableBytes.length,
          },
        },
        'windows': {
          'url': 'https://marcotv.wlj9919.top/movie/MarcoMovie-0.7.2-windows-setup.exe',
          'sha256': setupSha,
          'size': setupBytes.length,
        },
      };

      final release = AppUpdate.parse(manifest, platform: 'windows');
      expect(
        release.windowsAssetFor(WindowsDistributionKind.installer)?.fileName,
        'MarcoMovie-0.7.2-windows-x64-setup.exe',
      );
      expect(
        release.windowsAssetFor(WindowsDistributionKind.portable)?.fileName,
        'MarcoMovie-0.7.2-windows-x64-portable.zip',
      );
      expect(
        AppUpdate.compareVersionRelation('0.7.2', '0.7.1'),
        UpdateVersionRelation.remoteNewer,
      );
      expect(
        AppUpdate.compareVersionRelation('0.7.1', '0.7.1'),
        UpdateVersionRelation.sameVersion,
      );
      expect(
        AppUpdate.compareVersionRelation('0.7.0', '0.7.1'),
        UpdateVersionRelation.remoteOlder,
      );

      final outDir = Directory.systemTemp.createTempSync('marco-win-dl-test-');
      addTearDown(() => outDir.deleteSync(recursive: true));

      // 1. Checksum mismatch must fail and leave zero staging/corrupt files
      final corruptClient = MockClient(
        (_) async => http.Response.bytes(
          List<int>.filled(portableBytes.length, 0x58),
          200,
        ),
      );
      await expectLater(
        release.downloadWindows(
          distribution: WindowsDistributionKind.portable,
          directory: outDir,
          cancellation: UpdateCancellation(),
          client: corruptClient,
        ),
        throwsFormatException,
      );
      expect(outDir.listSync(), isEmpty);

      // 2. Valid portable download writes exact published portable filename
      final goodClient = MockClient((req) async {
        if (req.url.path.endsWith('portable.zip')) {
          return http.Response.bytes(portableBytes, 200);
        }
        return http.Response.bytes(setupBytes, 200);
      });
      final savedZip = await release.downloadWindows(
        distribution: WindowsDistributionKind.portable,
        directory: outDir,
        cancellation: UpdateCancellation(),
        client: goodClient,
      );
      final zipFileName = savedZip.uri.pathSegments.last;
      debugPrint('EVIDENCE_3_PORTABLE_PACKAGE: $zipFileName (path=${savedZip.path})');
      expect(zipFileName, 'MarcoMovie-0.7.2-windows-x64-portable.zip');
      expect(await savedZip.readAsBytes(), portableBytes);
      expect(
        outDir.listSync().whereType<Directory>().where(
              (d) => d.path.contains('.marco-win-update-'),
            ),
        isEmpty,
      );
    });

    testWidgets(
      'WindowsUpdateSheet handles older manifest (no downgrade), offline retry, checksum retry, installer upgrade & portable zip flow',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        final setupBytes = utf8.encode('WIN_SETUP_BYTES_072');
        final setupSha = sha256.convert(setupBytes).toString();
        final portableBytes = utf8.encode('WIN_PORTABLE_BYTES_072');
        final portableSha = sha256.convert(portableBytes).toString();

        AppUpdate makeRelease(String ver) => AppUpdate(
              ver,
              '### 本次更新\n- 修复播放与更新流程',
              Uri.parse(
                'https://marcotv.wlj9919.top/movie/MarcoMovie-$ver-windows-x64-setup.exe',
              ),
              setupSha,
              setupBytes.length,
              null,
              null,
              null,
              null,
              'MarcoMovie-$ver-windows-x64-setup.exe',
              UpdateAsset(
                fileName: 'MarcoMovie-$ver-windows-x64-setup.exe',
                url: Uri.parse(
                  'https://marcotv.wlj9919.top/movie/MarcoMovie-$ver-windows-x64-setup.exe',
                ),
                checksum: setupSha,
                size: setupBytes.length,
              ),
              UpdateAsset(
                fileName: 'MarcoMovie-$ver-windows-x64-portable.zip',
                url: Uri.parse(
                  'https://marcotv.wlj9919.top/movie/MarcoMovie-$ver-windows-x64-portable.zip',
                ),
                checksum: portableSha,
                size: portableBytes.length,
              ),
            );

        // 1. Local 0.7.1 vs Remote 0.7.0 (older manifest) -> NO download button!
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsUpdateSheet(
                key: const ValueKey('sheet-older'),
                installedVersion: '0.7.1',
                readVersion: () async => '0.7.1',
                detectInstall: () async => const WindowsInstallInfo(
                  distribution: WindowsDistributionKind.installer,
                  executablePath: r'C:\Apps\Marco Movie\marco_movie.exe',
                  installDirectory: r'C:\Apps\Marco Movie',
                ),
                check: (_, __) async => makeRelease('0.7.0'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('高于线上正式版（v0.7.0）'), findsOneWidget);
        expect(find.byKey(const ValueKey('windows-update-primary-action')), findsNothing);
        expect(find.textContaining('重新下载安装 v0.7.0'), findsNothing);

        // 2. Offline check -> retry succeeds -> Portable downloads ZIP, never runs setup
        var checkAttempt = 0;
        var downloadAttempt = 0;
        final launchedSetupArgs = <String>[];
        final revealedZips = <String>[];
        final tempDir = Directory.systemTemp.createTempSync('marco-sheet-portable-');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsUpdateSheet(
                key: const ValueKey('sheet-portable'),
                installedVersion: '0.7.1',
                readVersion: () async => '0.7.1',
                detectInstall: () async => const WindowsInstallInfo(
                  distribution: WindowsDistributionKind.portable,
                  executablePath: r'D:\Portable\MarcoMovie\marco_movie.exe',
                  installDirectory: r'D:\Portable\MarcoMovie',
                ),
                resolveDownloadDirectory: (_) async => tempDir,
                check: (_, __) async {
                  checkAttempt++;
                  if (checkAttempt == 1) {
                    throw const SocketException('Offline');
                  }
                  return makeRelease('0.7.2');
                },
                download: (release, dist, dir, cancel, onProgress) async {
                  expect(dist, WindowsDistributionKind.portable);
                  downloadAttempt++;
                  if (downloadAttempt == 1) {
                    throw const FormatException('更新包校验失败，请重新下载');
                  }
                  final asset = release.windowsAssetFor(dist)!;
                  final f = File('${dir.path}${Platform.pathSeparator}${asset.fileName}');
                  f.writeAsBytesSync(portableBytes);
                  onProgress(portableBytes.length, portableBytes.length);
                  return f;
                },
                launchInstaller: (file, dir) async {
                  launchedSetupArgs.add('${file.path}::$dir');
                },
                revealPortableZip: (file) async {
                  revealedZips.add(file.path);
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('windows-update-retry-check')), findsOneWidget);

        // Retry check -> now finds 0.7.2 portable
        await tester.tap(find.byKey(const ValueKey('windows-update-retry-check')));
        await tester.pumpAndSettle();
        expect(find.text('下载便携更新包 v0.7.2'), findsOneWidget);

        // First download fails checksum -> shows retry
        await tester.tap(find.byKey(const ValueKey('windows-update-primary-action')));
        await tester.pumpAndSettle();
        expect(find.textContaining('校验失败'), findsOneWidget);
        expect(find.text('重试下载便携包 v0.7.2'), findsOneWidget);

        // Second download succeeds -> reveals portable ZIP, NEVER launches setup
        await tester.tap(find.byKey(const ValueKey('windows-update-primary-action')));
        await tester.pumpAndSettle();
        expect(launchedSetupArgs, isEmpty);
        expect(revealedZips.length, 1);
        expect(revealedZips.single, endsWith('MarcoMovie-0.7.2-windows-x64-portable.zip'));

        // 3. Installer edition -> downloads setup EXE and launches with current install dir
        final installedDirCalls = <({String exe, String dir})>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowsUpdateSheet(
                key: const ValueKey('sheet-installer'),
                installedVersion: '0.7.1',
                readVersion: () async => '0.7.1',
                detectInstall: () async => const WindowsInstallInfo(
                  distribution: WindowsDistributionKind.installer,
                  executablePath: r'D:\IsolatedInstall\Marco Movie\marco_movie.exe',
                  installDirectory: r'D:\IsolatedInstall\Marco Movie',
                  matchedRegisteredInstall: true,
                  hasLocalUninstaller: true,
                ),
                resolveDownloadDirectory: (_) async => tempDir,
                check: (_, __) async => makeRelease('0.7.2'),
                download: (release, dist, dir, cancel, onProgress) async {
                  expect(dist, WindowsDistributionKind.installer);
                  final asset = release.windowsAssetFor(dist)!;
                  final f = File('${dir.path}${Platform.pathSeparator}${asset.fileName}');
                  f.writeAsBytesSync(setupBytes);
                  onProgress(setupBytes.length, setupBytes.length);
                  return f;
                },
                launchInstaller: (file, dir) async {
                  installedDirCalls.add((exe: file.path, dir: dir));
                },
                revealPortableZip: (_) async {
                  fail('Installer mode must not open portable explorer flow');
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('一键下载安装 v0.7.2'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('windows-update-primary-action')));
        await tester.pumpAndSettle();
        expect(installedDirCalls.length, 1);
        expect(installedDirCalls.single.exe, endsWith('MarcoMovie-0.7.2-windows-x64-setup.exe'));
        expect(installedDirCalls.single.dir, r'D:\IsolatedInstall\Marco Movie');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  // =========================================================================
  // P2B: Live Mini-Player Expand Preserves Active Channel & Route
  // =========================================================================
  group('P2B: Live embedded mini-player expand preserves active channel & route', () {
    testWidgets(
      'Dual-route auto-fallback to backup then expand hits backup route on FIRST request; manual channel switch then expand stays on new channel',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const size = Size(1280, 800);
        await tester.binding.setSurfaceSize(size);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        late HttpServer server;
        final httpRequestPaths = <String>[];
        await tester.runAsync(() async {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((req) async {
            httpRequestPaths.add(req.uri.path);
            if (req.uri.path == '/primary.ts') {
              req.response.statusCode = 502;
              await req.response.close();
              return;
            }
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType('video', 'mp2t');
            req.response.add(List<int>.filled(188, 0x47));
            await req.response.close();
          });
        });
        addTearDown(() async => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final dualChannel = LiveChannel(
          name: '双线测试台',
          group: '本地测试',
          urls: ['$baseUrl/primary.ts', '$baseUrl/backup.ts'],
        );
        final secondChannel = LiveChannel(
          name: '手动切换台B',
          group: '本地测试',
          urls: ['$baseUrl/channel_b.ts'],
        );
        final client = _StubClient(
          groups: [
            LiveGroup(
              name: '本地测试',
              channels: [dualChannel, secondChannel],
            ),
          ],
        );

        final storage = await initTestStorage();
        await tester.runAsync(() => storage.saveConfig(jsonEncode({
              'lives': [
                {'name': '本地直播源', 'url': '$baseUrl/live.m3u'},
              ],
              'sites': [
                {'key': 's1', 'name': '测试源', 'type': 1, 'api': 'https://owned.invalid/api'},
              ],
            })));

        final embeddedOpened = <String>[];
        final expandedOpened = <String>[];
        final createdPlayers = <_RecordingPlayer>[];

        _RecordingPlayer createLivePlayer({required bool embedded}) {
          final p = _RecordingPlayer(
            onOpen: (self, media) async {
              if (embedded) {
                embeddedOpened.add(media.uri);
              } else {
                expandedOpened.add(media.uri);
              }
              final uri = Uri.parse(media.uri);
              // Actually probe the local HTTP server so real server logs record the request!
              int status = 200;
              await HttpOverrides.runWithHttpOverrides(() async {
                final hc = HttpClient();
                try {
                  final req = await hc.getUrl(uri);
                  final resp = await req.close();
                  status = resp.statusCode;
                  await resp.drain<void>();
                } finally {
                  hc.close(force: true);
                }
              }, _RealHttpOverrides());
              if (status >= 400) {
                scheduleMicrotask(() => self.emitError('Server returned $status'));
                return;
              }
              self._state.playingValue = true;
              self._state.bufferingValue = false;
              self._state.positionValue = const Duration(milliseconds: 500);
              if (!self.disposed) {
                self._stream.widthCtrl.add(1280);
                self._stream.heightCtrl.add(720);
                self._stream.bufferingCtrl.add(false);
                self._stream.playingCtrl.add(true);
                self._stream.positionCtrl.add(const Duration(milliseconds: 500));
              }
            },
          );
          createdPlayers.add(p);
          return p;
        }

        final tempDir = Directory.systemTemp.createTempSync('marco-live-expand-');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final appearance = WindowsAppearance(tempDir);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: AdaptiveShell(
              storage: storage,
              client: client,
              onSetPreventCloseForTest: (_) async {},
              debugPlayerFactoryForTest: createLivePlayer,
              debugVideoSurfaceForTest: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to 直播 and click 双线测试台
        await tester.tap(find.text('直播').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('双线测试台').first);
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (embeddedOpened.isNotEmpty && embeddedOpened.last.endsWith('/backup.ts')) {
            break;
          }
        }
        debugPrint('P2B_EMBEDDED_OPENED: $embeddedOpened | HTTP: $httpRequestPaths');

        // Embedded player should have tried primary.ts, failed, and succeeded on backup.ts!
        expect(embeddedOpened.any((u) => u.endsWith('/primary.ts')), isTrue);
        expect(embeddedOpened.last, endsWith('/backup.ts'));

        // Record HTTP request index before clicking Expand
        final reqCountBeforeExpand = httpRequestPaths.length;

        // Click Expand on embedded player
        final expandBtn = find.byTooltip('展开播放');
        expect(expandBtn, findsOneWidget);
        await tester.tap(expandBtn);
        for (var i = 0; i < 15 && expandedOpened.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final requestsAfterExpand = httpRequestPaths.sublist(reqCountBeforeExpand);
        expect(expandedOpened, isNotEmpty);
        expect(expandedOpened.first, endsWith('/backup.ts'));
        expect(requestsAfterExpand.first, '/backup.ts');
        expect(requestsAfterExpand, isNot(contains('/primary.ts')));

        // Pop expanded PlayerScreen back to Live tab
        final navState = tester.state<NavigatorState>(find.byType(Navigator).first);
        navState.pop();
        await tester.pump(const Duration(milliseconds: 400));

        // Scenario 2: Start on 双线测试台, manually switch channel inside embedded mini-player to 手动切换台B, then expand
        expandedOpened.clear();
        await tester.tap(find.text('双线测试台').first);
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }

        // Open channel switcher inside embedded player (更多 -> 切换频道)
        final embeddedPlayerFinder = find.byType(PlayerScreen);
        expect(embeddedPlayerFinder, findsOneWidget);
        final moreBtn = find.descendant(
          of: embeddedPlayerFinder,
          matching: find.byTooltip('更多'),
        );
        if (moreBtn.evaluate().isEmpty) {
          await tester.tap(embeddedPlayerFinder);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(moreBtn, findsOneWidget);
        await tester.tap(moreBtn);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('切换频道').last);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('手动切换台B').last);
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (embeddedOpened.isNotEmpty &&
              embeddedOpened.last.endsWith('/channel_b.ts')) {
            break;
          }
        }
        expect(embeddedOpened.last, endsWith('/channel_b.ts'));

        final reqCountBeforeExpand2 = httpRequestPaths.length;
        final expandBtn2 = find.byTooltip('展开播放');
        if (expandBtn2.evaluate().isEmpty) {
          await tester.tap(embeddedPlayerFinder);
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(expandBtn2, findsOneWidget);
        await tester.tap(expandBtn2);
        for (var i = 0; i < 12 && expandedOpened.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final requestsAfterExpand2 =
            httpRequestPaths.sublist(reqCountBeforeExpand2);
        expect(expandedOpened.first, endsWith('/channel_b.ts'));
        expect(requestsAfterExpand2.first, '/channel_b.ts');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 400));
        for (final p in createdPlayers) {
          await p.dispose();
        }
      },
    );
  });

  // =========================================================================
  // P3: Cold Start Non-Blocking Restore & Windows Mine Page Benchmarks
  // =========================================================================
  group('P3: Cold start DownloadService & Windows Mine page responsiveness', () {
    test(
      'Cold start does not block on disconnected/slow Downloads or file verification; bounded concurrency <= 4; enqueue during restore never lost; queue restores only once',
      () async {
        final tempRoot = Directory.systemTemp.createTempSync('marco-coldstart-after-');
        addTearDown(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          try {
            if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
          } catch (_) {}
        });

        final supportDir = Directory('${tempRoot.path}/support')
          ..createSync(recursive: true);
        final existingFile = File('${tempRoot.path}/present.mp4')
          ..writeAsStringSync('VIDEO_DATA');
        final tasksJson = [
          for (var i = 0; i < 16; i++)
            {
              'id': 'restored_$i',
              'siteKey': 's1',
              'siteName': '源1',
              'siteApi': 'https://owned.invalid/api',
              'siteType': 1,
              'videoId': 'v$i',
              'title': '离线影片 $i',
              'poster': '',
              'lineName': '主线',
              'episodeName': '第${i + 1}集',
              'episodeIndex': i,
              'sourceUrl': 'https://owned.invalid/$i.mp4',
              'headers': <String, String>{},
              'createdAt': 1000000 + i,
              'status': 'completed',
              'progress': 1.0,
              'receivedBytes': 1024,
              'totalBytes': 1024,
              'filePath': i.isEven ? existingFile.path : '${tempRoot.path}/gone_$i.mp4',
              'error': '',
            },
        ];
        File('${supportDir.path}/marco_downloads.json')
            .writeAsStringSync(jsonEncode(tasksJson));

        // Simulate disconnected/slow Downloads directory (fails after 250ms)
        PathProviderPlatform.instance = _ConfigurablePathProvider(
          tempRoot,
          downloadsDelay: const Duration(milliseconds: 250),
          failDownloads: true,
        );

        final service = DownloadService.instance;
        service.resetForTesting();
        addTearDown(service.resetForTesting);

        var inFlightProbes = 0;
        var maxConcurrentProbes = 0;
        var totalProbes = 0;
        service.maxVerifyConcurrency = 4;
        service.debugFileExistsProbe = (path) async {
          inFlightProbes++;
          totalProbes++;
          maxConcurrentProbes = math.max(maxConcurrentProbes, inFlightProbes);
          await Future<void>.delayed(const Duration(milliseconds: 40));
          inFlightProbes--;
          return File(path).exists();
        };

        final swStart = Stopwatch()..start();
        // Fire init without awaiting (same as main.dart cold start)
        final init1 = service.init(_StubClient());
        final init2 = service.init(_StubClient()); // concurrent duplicate call
        swStart.stop();
        // UI launch is immediate (< 20ms), does NOT block on slow Downloads or 16*40ms probes!
        expect(swStart.elapsedMilliseconds, lessThan(50));

        // Click download WHILE restore is still in flight!
        final added = service.enqueue(
          site: const CmsSite(
            key: 's1',
            name: '源1',
            type: 1,
            api: 'https://owned.invalid/api',
          ),
          video: const CmsVideo(id: 'new_during_restore', title: '恢复期新任务'),
          line: const CmsLine(name: '主线', episodes: [
            CmsEpisode(name: '第01集', url: 'https://owned.invalid/new.mp4'),
          ]),
          episodeIndexes: [0],
        );
        expect(added, 1);
        service.pause(service.taskFor('s1', 'new_during_restore', '主线', 0)!.id);

        await Future.wait([init1, init2]);
        // Sequential duplicate init must also be a no-op
        await service.init(_StubClient());

        expect(service.isReady, isTrue);
        expect(service.restoreCount, 1);
        expect(service.tasks.length, 17); // 16 restored + 1 added during restore
        expect(
          service.taskFor('s1', 'new_during_restore', '主线', 0),
          isNotNull,
          reason: 'Task clicked during restore must never be lost',
        );
        // Fallback to Documents directory when Downloads is disconnected
        expect(service.rootPath, contains('documents'));

        // Background verification runs with bounded concurrency <= 4
        await service.verificationFuture;
        expect(totalProbes, 16);
        expect(maxConcurrentProbes, inInclusiveRange(1, 4));
        final failedRestored = service.tasks
            .where((t) => t.id.startsWith('restored_') && t.status == DownloadStatus.failed)
            .length;
        final intactRestored = service.tasks
            .where((t) => t.id.startsWith('restored_') && t.status == DownloadStatus.completed)
            .length;
        expect(failedRestored, 8);
        expect(intactRestored, 8);

        debugPrint(
          'AFTER_P3A_COLDSTART: launchBlockMs=${swStart.elapsedMilliseconds}, '
          'restoreCount=${service.restoreCount}, '
          'maxVerifyConcurrency=$maxConcurrentProbes, '
          'tasksAfterMerge=${service.tasks.length}',
        );
      },
    );

    testWidgets(
      'AFTER BENCHMARK P3B: Mine page 120 favorites, 60 history, 30 updating downloads — lazy viewport build, resize, scroll preservation',
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const size = Size(1280, 800);
        await tester.binding.setSurfaceSize(size);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tempRoot = Directory.systemTemp.createTempSync('marco-bench-after-');
        addTearDown(() async {
          try {
            await DownloadService.instance.flushSavesForTesting();
          } catch (_) {}
          for (var attempt = 0; attempt < 5; attempt++) {
            try {
              if (tempRoot.existsSync()) {
                tempRoot.deleteSync(recursive: true);
              }
              break;
            } catch (_) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }
        });
        PathProviderPlatform.instance = _ConfigurablePathProvider(tempRoot);

        final favList = [
          for (var i = 0; i < 120; i++)
            {
              'site': 's1',
              'id': 'fav_$i',
              'title': '收藏影片 $i',
              'poster': '',
              'remarks': '',
              'added': 1000000 + i,
            },
        ];
        final histList = [
          for (var i = 0; i < 60; i++)
            {
              'site': 's1',
              'id': 'hist_$i',
              'title': '历史影片 $i',
              'poster': '',
              'line': '主线',
              'episode': '第 ${i + 1} 集',
              'index': i,
              'position': 180000,
              'duration': 2400000,
              'updated': 1000000 + i,
            },
        ];

        final storage = await initTestStorage(initialPrefs: {
          StorageService.keyFavorites: jsonEncode(favList),
          StorageService.keyWatchHistory: jsonEncode(histList),
        });
        await tester.runAsync(() async {
          await storage.saveConfig(jsonEncode({
            'sites': [
              {'key': 's1', 'name': '源1', 'type': 1, 'api': 'https://owned.invalid/api'},
            ],
          }));
        });

        final dlService = DownloadService.instance;
        dlService.resetForTesting();
        addTearDown(dlService.resetForTesting);
        await tester.runAsync(() async {
          await dlService.init(_StubClient());
          for (var i = 0; i < 30; i++) {
            dlService.enqueue(
              site: const CmsSite(
                key: 's1',
                name: '源1',
                type: 1,
                api: 'https://owned.invalid/api',
              ),
              video: CmsVideo(id: 'dl_$i', title: '下载影片 $i'),
              line: CmsLine(name: '主线', episodes: [
                CmsEpisode(name: '第${i + 1}集', url: 'https://owned.invalid/dl_$i.mp4'),
              ]),
              episodeIndexes: [0],
            );
          }
          dlService.pauseAll();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });

        final appearance = WindowsAppearance(tempRoot);
        addTearDown(appearance.dispose);

        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) =>
                WindowsAppearanceScope(controller: appearance, child: child!),
            home: AdaptiveShell(
              storage: storage,
              client: _StubClient(),
              onSetPreventCloseForTest: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 我的 -> 收藏 (120 favorites)
        final swFavFirst = Stopwatch()..start();
        await tester.tap(find.text('我的').first);
        await tester.pump();
        swFavFirst.stop();
        await tester.pumpAndSettle();

        expect(find.byType(GridView), findsOneWidget);
        final favPostersMounted = find.byType(PosterImage).evaluate().length;
        expect(favPostersMounted, lessThan(30));

        // Measure scroll frames AND verify scroll position preservation
        final favScrollableFinder = find.byKey(
          const PageStorageKey<String>('windows-library-favorites'),
        );
        final favScrollTimesUs = <int>[];
        for (var step = 0; step < 10; step++) {
          final sw = Stopwatch()..start();
          await tester.drag(favScrollableFinder, const Offset(0, -320));
          await tester.pump();
          sw.stop();
          favScrollTimesUs.add(sw.elapsedMicroseconds);
        }
        final favScrollOffsetBeforeSwitch = tester
            .state<ScrollableState>(
              find.descendant(
                of: favScrollableFinder,
                matching: find.byType(Scrollable),
              ),
            )
            .position
            .pixels;
        expect(favScrollOffsetBeforeSwitch, greaterThan(200));

        // 2. Switch to 继续观看 (60 history)
        final swHistFirst = Stopwatch()..start();
        await tester.tap(find.text('继续观看').first);
        await tester.pump();
        swHistFirst.stop();
        await tester.pumpAndSettle();

        final histPostersMounted = find.byType(PosterImage).evaluate().length;
        expect(histPostersMounted, lessThan(30));
        final histScrollableFinder = find.byKey(
          const PageStorageKey<String>('windows-library-history'),
        );
        final histScrollTimesUs = <int>[];
        for (var step = 0; step < 8; step++) {
          final sw = Stopwatch()..start();
          await tester.drag(histScrollableFinder, const Offset(0, -320));
          await tester.pump();
          sw.stop();
          histScrollTimesUs.add(sw.elapsedMicroseconds);
        }

        // Switch back to 收藏 -> scroll position MUST be preserved!
        await tester.tap(find.text('收藏').first);
        await tester.pumpAndSettle();
        final favScrollOffsetAfterReturn = tester
            .state<ScrollableState>(
              find.descendant(
                of: favScrollableFinder,
                matching: find.byType(Scrollable),
              ),
            )
            .position
            .pixels;
        expect(
          favScrollOffsetAfterReturn,
          closeTo(favScrollOffsetBeforeSwitch, 1.0),
        );

        // Verify window resizing keeps layout overflow-free
        for (final nextSize in [const Size(820, 620), const Size(1500, 900)]) {
          await tester.binding.setSurfaceSize(nextSize);
          tester.view.physicalSize = nextSize;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.binding.setSurfaceSize(size);
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();

        // 3. Switch to 下载 (30 updating tasks)
        await tester.tap(find.text('下载').first);
        await tester.pumpAndSettle();
        final dlRefreshTimesUs = <int>[];
        final firstTask = dlService.tasks.first;
        final sortCountBeforeTicks = dlService.tasksSortCount;
        for (var tick = 1; tick <= 20; tick++) {
          firstTask.progress = tick / 20.0;
          firstTask.receivedBytes = tick * 1024 * 1024;
          final sw = Stopwatch()..start();
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          dlService.notifyListeners();
          await tester.pump();
          sw.stop();
          dlRefreshTimesUs.add(sw.elapsedMicroseconds);
        }
        final sortDeltaDuringTicks = dlService.tasksSortCount - sortCountBeforeTicks;
        expect(
          sortDeltaDuringTicks,
          0,
          reason: 'Progress ticks should reuse cached sorted tasks without per-row re-sorting',
        );

        final avgFavScrollMs =
            favScrollTimesUs.reduce((a, b) => a + b) / favScrollTimesUs.length / 1000.0;
        final avgHistScrollMs =
            histScrollTimesUs.reduce((a, b) => a + b) / histScrollTimesUs.length / 1000.0;
        final avgDlRefreshMs =
            dlRefreshTimesUs.reduce((a, b) => a + b) / dlRefreshTimesUs.length / 1000.0;

        debugPrint(
          'AFTER_P3B_METRICS: '
          'favMountedCards=$favPostersMounted/120, '
          'favFirstFrameMs=${(swFavFirst.elapsedMicroseconds / 1000.0).toStringAsFixed(2)}, '
          'favAvgScrollMs=${avgFavScrollMs.toStringAsFixed(2)}, '
          'histMountedCards=$histPostersMounted/60, '
          'histFirstFrameMs=${(swHistFirst.elapsedMicroseconds / 1000.0).toStringAsFixed(2)}, '
          'histAvgScrollMs=${avgHistScrollMs.toStringAsFixed(2)}, '
          'dlAvgRefreshMs=${avgDlRefreshMs.toStringAsFixed(2)}, '
          'dlSortsDuring20Ticks=$sortDeltaDuringTicks',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  });
}

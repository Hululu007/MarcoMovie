import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
import 'package:marco_movie/core/ios_avplayer_controller.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/personal_netdisk_library.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/core/windows_appearance_preferences.dart';
import 'package:marco_movie/core/wogg_source.dart';
import 'package:marco_movie/ui/ios_press_slide_menu.dart';
import 'package:marco_movie/ui/media_folder_browser_page.dart';
import 'package:marco_movie/ui/personal_netdisk_picker_page.dart';
import 'package:marco_movie/ui/player/ios_player_chrome.dart';
import 'package:marco_movie/ui/player/player_hud_prefs.dart';
import 'package:marco_movie/ui/player_screen.dart';

class _DiskWriteFailureFileStore extends InMemoryStorageFileStore {
  bool rejectHistoryWrites = false;

  @override
  Future<void> writeStringAndFlush(String name, String text) async {
    if (rejectHistoryWrites && name.startsWith('watch_history')) {
      throw const FileSystemException('Storage is full');
    }
    await super.writeStringAndFlush(name, text);
  }
}

class _GatedHistoryFileStore extends _DiskWriteFailureFileStore {
  Completer<void>? firstWriteStarted;
  Completer<void>? allowFirstWrite;
  bool _gatedOnce = false;

  @override
  Future<void> writeStringAndFlush(String name, String text) async {
    if (!_gatedOnce &&
        allowFirstWrite != null &&
        name.startsWith('watch_history')) {
      _gatedOnce = true;
      firstWriteStarted?.complete();
      await allowFirstWrite!.future;
    }
    await super.writeStringAndFlush(name, text);
  }
}

class _TransientReadLockFileStore extends _DiskWriteFailureFileStore {
  bool readLocked = false;
  bool rejectQuarantineWrites = false;

  @override
  List<int> readBytesSync(String name) {
    if (readLocked && name == 'watch_history.json') {
      throw const FileSystemException('Temporary protected file');
    }
    return super.readBytesSync(name);
  }

  @override
  void writeBytesSync(String name, List<int> bytes) {
    if (rejectQuarantineWrites && name.startsWith('watch_history_corrupt_')) {
      throw const FileSystemException('Quarantine archive write rejected');
    }
    super.writeBytesSync(name, bytes);
  }
}

class _FailingHistoryPrefsStore extends InMemorySharedPreferencesStore {
  _FailingHistoryPrefsStore() : super.withData(<String, Object>{});
  bool throwOnHistoryMirror = false;
  bool throwOnQuarantinePrefs = false;
  bool refusePendingMarker = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${StorageService.keyWatchHistory}' &&
        throwOnHistoryMirror) {
      throw PlatformException(
        code: 'storage_error',
        message: 'Simulated preferences write failure',
      );
    }
    if (key.startsWith('flutter.watch_history_corrupt_') &&
        throwOnQuarantinePrefs) {
      return Future<bool>.error(
        PlatformException(
          code: 'prefs_quarantine_error',
          message: 'Simulated quarantine prefs failure',
        ),
      );
    }
    if (key == 'flutter.${StorageService.keyWatchHistoryPrefsPendingFlush}' &&
        refusePendingMarker &&
        value == true) {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _SilentFakePlayerStreams implements PlayerStream {
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _buf = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _vol = StreamController<double>.broadcast();
  final _rate = StreamController<double>.broadcast();
  final _err = StreamController<String>.broadcast();
  final _tracks = StreamController<Tracks>.broadcast();
  final _track = StreamController<Track>.broadcast();
  final _playlist = StreamController<Playlist>.broadcast();
  final _width = StreamController<int?>.broadcast();
  final _height = StreamController<int?>.broadcast();
  final _sub = StreamController<List<String>>.broadcast();
  final _log = StreamController<PlayerLog>.broadcast();
  final _audioParams = StreamController<AudioParams>.broadcast();
  final _videoParams = StreamController<VideoParams>.broadcast();
  final _audioBitrate = StreamController<double?>.broadcast();
  final _audioDevice = StreamController<AudioDevice>.broadcast();
  final _audioDevices = StreamController<List<AudioDevice>>.broadcast();
  final _pitch = StreamController<double>.broadcast();
  final _shuffle = StreamController<bool>.broadcast();
  final _playlistMode = StreamController<PlaylistMode>.broadcast();

  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<Duration> get duration => _dur.stream;
  @override
  Stream<Duration> get buffer => _buf.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<double> get bufferingPercentage => const Stream<double>.empty();
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<double> get volume => _vol.stream;
  @override
  Stream<double> get rate => _rate.stream;
  @override
  Stream<String> get error => _err.stream;
  @override
  Stream<Tracks> get tracks => _tracks.stream;
  @override
  Stream<Track> get track => _track.stream;
  @override
  Stream<Playlist> get playlist => _playlist.stream;
  @override
  Stream<int?> get width => _width.stream;
  @override
  Stream<int?> get height => _height.stream;
  @override
  Stream<List<String>> get subtitle => _sub.stream;
  @override
  Stream<PlayerLog> get log => _log.stream;
  @override
  Stream<AudioParams> get audioParams => _audioParams.stream;
  @override
  Stream<VideoParams> get videoParams => _videoParams.stream;
  @override
  Stream<double?> get audioBitrate => _audioBitrate.stream;
  @override
  Stream<AudioDevice> get audioDevice => _audioDevice.stream;
  @override
  Stream<List<AudioDevice>> get audioDevices => _audioDevices.stream;
  @override
  Stream<double> get pitch => _pitch.stream;
  @override
  Stream<bool> get shuffle => _shuffle.stream;
  @override
  Stream<PlaylistMode> get playlistMode => _playlistMode.stream;

  void close() {
    _pos.close();
    _dur.close();
    _buf.close();
    _playing.close();
    _buffering.close();
    _completed.close();
    _vol.close();
    _rate.close();
    _err.close();
    _tracks.close();
    _track.close();
    _playlist.close();
    _width.close();
    _height.close();
    _sub.close();
    _log.close();
    _audioParams.close();
    _videoParams.close();
    _audioBitrate.close();
    _audioDevice.close();
    _audioDevices.close();
    _pitch.close();
    _shuffle.close();
    _playlistMode.close();
  }
}

class _SilentFakePlayer implements Player {
  final _streams = _SilentFakePlayerStreams();
  @override
  final PlayerState state = PlayerState();
  @override
  PlayerStream get stream => _streams;
  @override
  PlatformPlayer? get platform => null;
  @override
  Future<int> get handle async => 0;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration duration) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> dispose() async => _streams.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubCloudDriveClient extends PersonalCloudDriveClient {
  _StubCloudDriveClient({
    required this.onList,
    this.onResolve,
  }) : super(credentialReader: (_) async => 'stub-cred');

  final Future<PersonalCloudPage> Function(
    PersonalCloudProvider provider,
    String folderId,
    int page,
  ) onList;
  final Future<CmsEpisode> Function(
    PersonalCloudProvider provider,
    String fileId,
    String expectedAccountId,
  )? onResolve;

  @override
  Future<PersonalCloudPage> listFolder(
    PersonalCloudProvider provider, {
    String folderId = '',
    int page = 1,
    String marker = '',
    String driveId = '',
  }) =>
      onList(provider, folderId, page);

  @override
  Future<CmsEpisode> resolveFile({
    required PersonalCloudProvider provider,
    required String fileId,
    required String name,
    String driveId = '',
    String path = '',
    String rawRef = '',
    String expectedAccountId = '',
    String expectedCookieAccountId = '',
  }) {
    if (onResolve != null) {
      return onResolve!(provider, fileId, expectedAccountId);
    }
    return Future<CmsEpisode>.value(
      CmsEpisode(name: name, url: 'https://cdn.example/$fileId.mp4'),
    );
  }
}

class _LegacyGestureHudPrefs extends PlayerHudPrefs {
  _LegacyGestureHudPrefs() : super(isDesktop: false, persist: false);

  @override
  bool get enhancedHudEnabled => false;
}

class _ReauthPage2CmsClient extends Fake implements CmsClient {
  @override
  Future<CmsListing> fetchCategory(
    CmsSite site,
    String typeId,
    int page, {
    List<String> childIds = const [],
    CmsFilter? filter,
  }) async {
    if (page == 1) {
      return const CmsListing(
        page: 1,
        pageCount: 2,
        videos: [
          CmsVideo(
            id: 'mmcloudlib://play?provider=ali&fid=1',
            title: '第一页影片.mp4',
            remarks: '1.2 GB',
          ),
        ],
      );
    }
    throw const PersonalCloudException(
      'auth_expired',
      '网盘登录已失效，请重新授权',
      requiresReauth: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iOS 0.7.7 GPT independent review regressions', () {
    testWidgets(
      'Item 1: fallback vertical drag waits for real system volume and reverts HUD on write failure',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final firstRead = Completer<double>();
        final writes = <double>[];
        var rejectWrites = false;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosAvPlayerController.defaultChannel,
                (MethodCall call) async {
          switch (call.method) {
            case 'getTelemetry':
              return <String, dynamic>{
                'thermalState': 'nominal',
                'isPipSupported': true,
                'isPipPossible': false,
                'isPipActive': false,
              };
            case 'getSystemVolume':
              return firstRead.future;
            case 'setSystemVolume':
              final next = (call.arguments as num).toDouble();
              writes.add(next);
              if (rejectWrites) {
                return <String, dynamic>{'applied': false, 'volume': 0.25};
              }
              return <String, dynamic>{'applied': true, 'volume': next};
            case 'open':
              return true;
            default:
              return null;
          }
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        // Force legacy GestureDetector path by disabling enhanced HUD gestures.
        final prefs = _LegacyGestureHudPrefs();
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: const CmsSite(
                key: 'vod1',
                name: '测试源',
                type: 1,
                api: 'https://vod.example/api',
              ),
              video: const CmsVideo(
                id: 'v1',
                title: '音量样片',
                lines: [
                  CmsLine(
                    name: '主线',
                    episodes: [
                      CmsEpisode(name: '第1集', url: 'https://cdn.example/1.mp4'),
                    ],
                  ),
                ],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              debugHudPrefs: prefs,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));

        // 1. Small upward drag while first hardware volume read is still pending.
        await tester.dragFrom(const Offset(700, 240), const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 50));
        expect(writes, isEmpty);

        // 2. Complete initial read at 2% -> buffered delta applies from 2%.
        firstRead.complete(0.02);
        await tester.pump(const Duration(milliseconds: 100));
        expect(writes, isNotEmpty);
        expect(writes.last, greaterThan(0.02));
        expect(writes.last, lessThan(0.35));

        // 3. Subsequent write failure (missing UISlider) reverts HUD to system-confirmed 25%.
        rejectWrites = true;
        await tester.dragFrom(const Offset(700, 260), const Offset(0, -100));
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('设备音量 25%'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Item 2: PiP waits for possible, cancels on live channel switch / MPV fallback / second tap, and preserves MPV pref',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var startPipCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(IosAvPlayerController.defaultChannel,
                (MethodCall call) async {
          switch (call.method) {
            case 'getTelemetry':
              return <String, dynamic>{
                'thermalState': 'nominal',
                'isPipSupported': true,
                'isPipPossible': false,
                'isPipActive': false,
                'systemVolume': 0.5,
              };
            case 'open':
              return true;
            case 'startPip':
              startPipCalls++;
              return false;
            default:
              return null;
          }
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
        });

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        await storage.setIosPlaybackEngineMode('avplayer');
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();
        const ch1 = LiveChannel(
          group: '央视',
          name: 'CCTV-1',
          urls: ['https://live.example/1.m3u8'],
        );
        const ch2 = LiveChannel(
          group: '央视',
          name: 'CCTV-2',
          urls: ['https://live.example/2.m3u8'],
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              site: const CmsSite(key: 'live', name: '直播', type: 1, api: ''),
              video: CmsVideo(
                id: 'live:cctv1',
                title: ch1.name,
                lines: [CmsLine(name: ch1.group, episodes: ch1.episodes)],
              ),
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              isLive: true,
              liveGroups: const [LiveGroup(name: '央视', channels: [ch1, ch2])],
              initialLiveChannel: ch1,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));

        // Tap PiP on CCTV-1 while not possible -> arms pending PiP
        await tester.tap(find.byKey(const Key('ios-live-companion-pip-btn')));
        await tester.pump(const Duration(milliseconds: 80));
        expect(startPipCalls, 1);

        // Switch channel to CCTV-2 -> must invalidate CCTV-1's pending PiP!
        await tester.tap(find.byKey(const ValueKey('ios-live-channel-card-央视-CCTV-2')));
        await tester.pump(const Duration(milliseconds: 120));

        avCtrl.handleNativeEvent(const {
          'type': 'pipStateChanged',
          'active': false,
          'supported': true,
          'possible': true,
        });
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          startPipCalls,
          1,
          reason: 'Switching live channel must cancel pending PiP from previous channel',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test('Item 4: Plex and WoGG duplicate-named files keep distinct identities', () {
      final plexA = WatchHistoryEntry.mediaIdentityForUrl(
        'mmplex://play?part=%2Flibrary%2Fparts%2F1001%2Fa.mkv',
      );
      final plexB = WatchHistoryEntry.mediaIdentityForUrl(
        'mmplex://play?part=%2Flibrary%2Fparts%2F1002%2Fb.mkv',
      );
      expect(plexA, isNot(equals(plexB)));

      const woggSite = CmsSite(
        key: 'wogg_test',
        name: '玩偶哥哥',
        type: 3,
        api: 'csp_Wogg',
        ext: '{"siteUrl":"https://wogg.example"}',
      );
      final bmB = WatchHistoryEntry(
        site: woggSite.key,
        id: 'w1',
        title: '样片',
        line: 'UC 1',
        episode: '正片',
        episodeMediaId: WatchHistoryEntry.mediaIdentityForUrl('mmcloud://uc?fid=b'),
        index: 1,
        position: 45000,
        duration: 120000,
        updated: 1000,
      );
      const bothVideo = CmsVideo(
        id: 'w1',
        title: '样片',
        lines: [
          CmsLine(
            name: 'UC 1',
            episodes: [
              CmsEpisode(name: '正片', url: 'mmcloud://uc?fid=a'),
              CmsEpisode(name: '正片', url: 'mmcloud://uc?fid=b'),
            ],
          ),
        ],
      );
      const onlyAVideo = CmsVideo(
        id: 'w1',
        title: '样片',
        lines: [
          CmsLine(
            name: 'UC 1',
            episodes: [
              CmsEpisode(name: '正片', url: 'mmcloud://uc?fid=a'),
            ],
          ),
        ],
      );
      expect(WoggSource.resolveCachedBookmarkTarget(woggSite, bothVideo, bmB), (0, 1));
      expect(WoggSource.resolveCachedBookmarkTarget(woggSite, onlyAVideo, bmB), isNull);
    });

    test('Item 5: restoreWatchHistoryEntry beats deletion tombstone in both sync orders', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storageA = await StorageService.init();
      final entry = WatchHistoryEntry(
        site: 's1',
        id: 'v1',
        title: '测试剧集',
        line: '主线',
        episode: '第3集',
        episodeMediaId: WatchHistoryEntry.mediaIdentityForUrl('https://cdn.example/3.m3u8'),
        index: 2,
        position: 125000,
        duration: 600000,
        updated: 1000000,
      );
      await storageA.upsertWatchHistory(entry, immediate: true, triggerSync: false);
      await storageA.removeWatchHistoryItem('s1', 'v1');
      final remoteDeletedPayload = storageA.exportSyncPayload();

      await storageA.restoreWatchHistoryEntry(entry);
      final afterUndoLocal = storageA.getWatchHistory();
      expect(afterUndoLocal, hasLength(1));
      expect(afterUndoLocal.single.position, 125000);

      // Merge remote deletion tombstone -> restored item must survive!
      await storageA.mergeSyncPayload(remoteDeletedPayload);
      final afterMerge = storageA.getWatchHistory();
      expect(afterMerge, hasLength(1));
      expect(afterMerge.single.position, 125000);
    });

    test('Item 6: PersonalCloudLibrary blocks account switch on home/list/resolve while allowing same-account refresh', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var currentAccount = 'account-A';
      final client = _StubCloudDriveClient(
        onList: (provider, folderId, page) async => PersonalCloudPage(
          provider: provider,
          folderId: folderId,
          items: [
            PersonalCloudItem(
              provider: provider,
              id: 'f1',
              name: '$currentAccount-movie.mp4',
              isDir: false,
            ),
          ],
          page: page,
          pageCount: 1,
          hasMore: false,
          accountId: currentAccount,
        ),
        onResolve: (provider, fileId, expectedAccountId) async {
          PersonalCloudDriveClient.assertAccountMatches(
            provider: provider,
            expectedAccountId: expectedAccountId,
            observedAccountId: currentAccount,
          );
          return CmsEpisode(name: 'movie', url: 'https://cdn.example/$fileId.mp4');
        },
      );

      final created = await PersonalCloudLibrary.create(
        client: client,
        provider: PersonalCloudProvider.ali,
        folderId: 'root',
        folderName: 'A目录',
        group: '测试',
        isPrivate: false,
      );
      final cfg = (jsonDecode(created.entry.rawContent) as Map)['sites'][0] as Map;
      final site = CmsSite(
        key: cfg['key'] as String,
        name: cfg['name'] as String,
        type: 1,
        api: cfg['api'] as String,
      );

      final lib = await PersonalCloudLibrary.open(site, client: client);
      final (_, homeListing) = await lib.home();
      expect(homeListing.videos.single.title, contains('account-A'));

      // Switch active account to B -> home, list, and resolve must all reject!
      currentAccount = 'account-B';
      await expectLater(lib.home(), throwsA(isA<PersonalCloudException>()));
      await expectLater(lib.list('root', '', 1), throwsA(isA<PersonalCloudException>()));
      await expectLater(
        lib.resolve(homeListing.videos.single.lines.single.episodes.single),
        throwsA(isA<PersonalCloudException>()),
      );

      // Switch back to account-A (e.g. same account refreshed token) -> succeeds!
      currentAccount = 'account-A';
      final (_, restoredListing) = await lib.home();
      expect(restoredListing.videos.single.title, contains('account-A'));
      final resolved = await lib.resolve(
        restoredListing.videos.single.lines.single.episodes.single,
      );
      expect(resolved.url, contains('f1.mp4'));
    });

    testWidgets(
      'Item 6: MediaFolderBrowserPage page-2 reauth keeps page-1 visible and exposes 重新授权',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init();
        await tester.pumpWidget(
          MaterialApp(
            home: MediaFolderBrowserPage(
              site: const CmsSite(
                key: 'cloud1',
                name: '阿里云盘',
                type: 1,
                api: 'cloudlib://account/demo',
              ),
              client: _ReauthPage2CmsClient(),
              storage: storage,
              folderId: 'root',
              folderTitle: '测试目录',
              onOpenVideo: (_, __) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('第一页影片.mp4'), findsOneWidget);

        await tester.tap(find.textContaining('加载更多'));
        await tester.pumpAndSettle();

        expect(find.text('第一页影片.mp4'), findsOneWidget);
        expect(find.text('重新授权').hitTestable(), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Item 6: PersonalNetdiskDirectoryPickerPage discards late subfolder response after Back',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          secureStore: InMemorySecureCredentialStore(),
        );
        await storage.setNetdiskCredential('uc', '__pus=local_fixture_token');
        final childCompleter = Completer<PersonalCloudPage>();
        final client = _StubCloudDriveClient(
          onList: (provider, folderId, page) {
            if (folderId == 'sub') return childCompleter.future;
            return Future<PersonalCloudPage>.value(
              PersonalCloudPage(
                provider: provider,
                folderId: folderId,
                items: const [
                  PersonalCloudItem(
                    provider: PersonalCloudProvider.uc,
                    id: 'sub',
                    name: '子目录',
                    isDir: true,
                  ),
                  PersonalCloudItem(
                    provider: PersonalCloudProvider.uc,
                    id: 'r1',
                    name: '根目录影片.mp4',
                    isDir: false,
                  ),
                ],
                page: 1,
                pageCount: 1,
                hasMore: false,
                accountId: 'accA',
              ),
            );
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: PersonalNetdiskPickerPage(
              provider: PersonalCloudProvider.uc,
              storage: storage,
              group: '测试',
              isPrivate: false,
              client: client,
              onLibrarySaved: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('根目录影片.mp4'), findsOneWidget);

        await tester.tap(find.text('子目录'));
        await tester.pump();
        await tester.tap(find.text(PersonalCloudProvider.uc.rootLabel));
        await tester.pumpAndSettle();

        childCompleter.complete(
          const PersonalCloudPage(
            provider: PersonalCloudProvider.uc,
            folderId: 'sub',
            items: [
              PersonalCloudItem(
                provider: PersonalCloudProvider.uc,
                id: 'c1',
                name: '仅在子目录.mp4',
                isDir: false,
              ),
            ],
            page: 1,
            pageCount: 1,
            hasMore: false,
            accountId: 'accA',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('仅在子目录.mp4'), findsNothing);
        expect(find.text('根目录影片.mp4'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'Item 9: IosPressSlideMenuAnchor blocks background semantics, restores focus, and scrolls at 3.0x text scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final semantics = tester.ensureSemantics();
        var backgroundActivations = 0;
        final anchorFocus = FocusNode();
        addTearDown(anchorFocus.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => backgroundActivations++,
                    child: const Text('下层页面操作'),
                  ),
                  Focus(
                    focusNode: anchorFocus,
                    child: IosPressSlideMenuAnchor(
                      openOnTap: true,
                      preferredAnchor: Alignment.topRight,
                      accessibilityLabel: '展开菜单',
                      itemsBuilder: () => [
                        for (var i = 1; i <= 12; i++)
                          IosSlideMenuAction(id: 'item_$i', title: '操作项 $i'),
                      ],
                      onSelected: (_) {},
                      child: const Text('底部菜单'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        anchorFocus.requestFocus();
        await tester.pump();
        expect(anchorFocus.hasFocus, isTrue);

        await tester.tap(find.text('底部菜单'));
        await tester.pumpAndSettle();
        expect(find.text('操作项 1'), findsOneWidget);

        // Background semantics action must be blocked while menu is open.
        final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
        void tryBg(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (!data.flagsCollection.isHidden &&
              data.label.contains('下层页面操作') &&
              data.hasAction(SemanticsAction.tap)) {
            owner.performAction(node.id, SemanticsAction.tap);
          }
          node.visitChildren((c) {
            tryBg(c);
            return true;
          });
        }
        tryBg(owner.rootSemanticsNode!);
        await tester.pump();
        expect(backgroundActivations, 0);

        // With 12 items at 3.0x text scale, the menu must clamp to available height and scroll.
        final scrollView = find.byType(SingleChildScrollView);
        expect(scrollView, findsOneWidget);
        final scrollableState = tester.state<ScrollableState>(
          find.descendant(of: scrollView, matching: find.byType(Scrollable)),
        );
        expect(scrollableState.position.maxScrollExtent, greaterThan(0));
        scrollableState.position.jumpTo(scrollableState.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('操作项 12').hitTestable(), findsOneWidget);

        // Tapping an item dismisses the menu and restores focus to previous node.
        await tester.tap(find.text('操作项 12'));
        await tester.pumpAndSettle();
        expect(anchorFocus.hasFocus, isTrue);

        semantics.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R2 P1-1: AVPlayer resume seek landing does not confirm playback until real clock progresses',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        int? openedMediaId;
        Future<void> emitAvEvent(Map<String, Object?> payload) async {
          final encoded = const StandardMethodCodec().encodeSuccessEnvelope(
            <String, Object?>{
              if (openedMediaId != null) 'mediaId': openedMediaId,
              ...payload,
            },
          );
          await messenger.handlePlatformMessage(
            IosAvPlayerController.defaultEventChannel.name,
            encoded,
            (_) {},
          );
        }

        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            switch (call.method) {
              case 'getTelemetry':
                return <String, Object?>{
                  'thermalState': 'nominal',
                  'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                  'isPipSupported': true,
                  'isPipPossible': true,
                  'isPipActive': false,
                  'systemVolume': 0.5,
                  'isAirPlayActive': false,
                };
              case 'open':
                openedMediaId = (call.arguments as Map)['mediaId'] as int?;
                return true;
              case 'seek':
                return true;
              default:
                return null;
            }
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        const site = CmsSite(
          key: 's_r2_seek',
          name: '测试源',
          type: 1,
          api: 'https://fixture.example/api',
        );
        const video = CmsVideo(
          id: 'vid_r2_seek',
          title: '续播确认测试',
          lines: [
            CmsLine(
              id: 'line_a',
              name: '线路A',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
              ],
            ),
          ],
        );
        var confirmCount = 0;
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();
        addTearDown(fakePlayer.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              initialPositionMs: 45000,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
              onPlaybackConfirmed: (_) => confirmCount++,
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(openedMediaId, isNotNull);

        await emitAvEvent(<String, Object?>{
          'type': 'ready',
          'positionMs': 0,
          'durationMs': 1800000,
          'width': 1920,
          'height': 1080,
        });
        await emitAvEvent(<String, Object?>{
          'type': 'playbackState',
          'playing': true,
          'buffering': false,
          'positionMs': 0,
          'durationMs': 1800000,
        });
        await tester.pump();
        final beforeLanding = confirmCount;

        // Seek lands at 45000ms: MUST NOT confirm playback yet.
        await emitAvEvent(<String, Object?>{
          'type': 'progress',
          'playing': true,
          'positionMs': 45000,
          'durationMs': 1800000,
        });
        await tester.pump();
        final atLanding = confirmCount;

        // Forward media clock advancement to 45250ms: confirms once.
        await emitAvEvent(<String, Object?>{
          'type': 'progress',
          'playing': true,
          'positionMs': 45250,
          'durationMs': 1800000,
        });
        await tester.pump();
        final afterProgress = confirmCount;

        expect([beforeLanding, atLanding, afterProgress], [0, 0, 1]);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R2 P1-2: Suspended PiP capability refresh from episode 1 never leaks startPip onto episode 2',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var telemetryCalls = 0;
        Completer<Map<String, Object?>>? pendingPipRefresh;
        final openMediaIds = <int>[];
        final pipStartMediaIds = <int>[];
        int? currentMediaId;

        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            switch (call.method) {
              case 'getTelemetry':
                telemetryCalls++;
                if (telemetryCalls == 1) {
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': false,
                    'isPipPossible': false,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                }
                pendingPipRefresh ??= Completer<Map<String, Object?>>();
                return pendingPipRefresh!.future;
              case 'open':
                currentMediaId = (call.arguments as Map)['mediaId'] as int?;
                if (currentMediaId != null) openMediaIds.add(currentMediaId!);
                return true;
              case 'startPip':
                if (currentMediaId != null) {
                  pipStartMediaIds.add(currentMediaId!);
                }
                return true;
              default:
                return null;
            }
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        const site = CmsSite(
          key: 's_r2_pip',
          name: '测试源',
          type: 1,
          api: 'https://fixture.example/api',
        );
        const video = CmsVideo(
          id: 'vid_r2_pip',
          title: '画中画跨集测试',
          lines: [
            CmsLine(
              id: 'line_a',
              name: '线路A',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                CmsEpisode(name: '第2集', url: 'https://cdn.example/ep2.m3u8'),
              ],
            ),
          ],
        );
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();
        addTearDown(fakePlayer.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(openMediaIds.length, 1);

        // Tap PiP on episode 1 -> suspends awaiting refreshTelemetry().
        final pipBtn = find.byKey(const Key('ios-vod-companion-pip-btn'));
        await tester.ensureVisible(pipBtn);
        expect(pipBtn, findsOneWidget);
        await tester.tap(pipBtn);
        await tester.pump();
        expect(pendingPipRefresh, isNotNull);

        // Switch to episode 2 before ep1's capability query resolves.
        final ep2 = find.byKey(const Key('ios-portrait-episode-1'));
        for (var i = 0; i < 8 && ep2.evaluate().isEmpty; i++) {
          await tester.dragFrom(const Offset(190, 700), const Offset(0, -200));
          await tester.pump();
        }
        await tester.ensureVisible(ep2);
        await tester.tap(ep2);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(openMediaIds.length, 2);

        // Now resolve ep1's stale capability query as supported.
        pendingPipRefresh!.complete(<String, Object?>{
          'thermalState': 'nominal',
          'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
          'isPipSupported': true,
          'isPipPossible': true,
          'isPipActive': false,
          'systemVolume': 0.5,
          'isAirPlayActive': false,
        });
        await tester.pump(const Duration(milliseconds: 100));

        expect(pipStartMediaIds, isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R2 P1-4, P1-5 & P2-1: Backup fallback survives restart, signed episodeMediaId is sanitized, and clock-skew re-delete wins sync',
      () async {
        // P1-4: Backup file write failure falls back to prefs and survives restart.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final disk = _DiskWriteFailureFileStore();
        Future<StorageService> openStorage() => StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );
        final storage = await openStorage();
        const previous = WatchHistoryEntry(
          site: 'site_a',
          id: 'previous',
          title: '旧记录',
          updated: 100,
        );
        const imported = WatchHistoryEntry(
          site: 'site_b',
          id: 'imported',
          title: '新导入记录',
          updated: 200,
        );
        await storage.upsertWatchHistory(
          previous,
          immediate: true,
          triggerSync: false,
        );
        expect(disk.readStringOrNull('watch_history.json'), contains('previous'));

        final backup = CmsParser.encodeBackupPayload(
          origin: '',
          rawConfig:
              '{"sites":[{"key":"site_b","name":"测试源","type":1,"api":"https://fixture.example/api"}]}',
          settings: <String, dynamic>{
            'watch_history': <Map<String, dynamic>>[
              <String, dynamic>{
                ...imported.toJson(),
                // P1-5: Inject signed URL directly in episodeMediaId.
                'episodeMediaId':
                    'https://cdn.example/video.mp4?token=r2-fixture-secret',
              },
            ],
          },
        );
        disk.rejectHistoryWrites = true;
        await storage.importBackupJson(backup);
        expect(storage.getWatchHistory().single.id, 'imported');

        // Restart once disk recovers: MUST load 'imported', NOT stale 'previous'.
        disk.rejectHistoryWrites = false;
        final reopened = await openStorage();
        final hist = reopened.getWatchHistory();
        expect(hist.single.id, 'imported');
        expect(
          WatchHistoryEntry.isCanonicalMediaId(hist.single.episodeMediaId),
          isTrue,
        );

        // P1-5: Neither backup export nor sync payload leaks the signed token.
        final exportedBackup = reopened.exportBackupJson();
        final exportedSync = jsonEncode(reopened.exportSyncPayload());
        expect(exportedBackup.contains('r2-fixture-secret'), isFalse);
        expect(exportedSync.contains('r2-fixture-secret'), isFalse);
        // Spoofed mid:v1 prefix with URL payload is also normalized.
        final spoofed = WatchHistoryEntry.fromJson(const <String, dynamic>{
          'site': 'site_b',
          'id': 'spoof',
          'title': '伪造前缀',
          'episodeMediaId': 'mid:v1:https://cdn.example/a.mp4?token=leak123',
        });
        expect(WatchHistoryEntry.isCanonicalMediaId(spoofed.effectiveMediaId), isTrue);
        expect(spoofed.toJson()['episodeMediaId'].toString().contains('leak123'), isFalse);

        // P2-1: Clock-skew delete -> Undo -> re-delete keeps tombstone newer than restored entry.
        final futureSkewMs =
            DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;
        final skewedRemote = WatchHistoryEntry(
          site: 'site_b',
          id: 'skewed_item',
          title: '时钟偏移剧集',
          updated: futureSkewMs,
        );
        await reopened.upsertWatchHistory(
          skewedRemote,
          immediate: true,
          triggerSync: false,
        );
        await reopened.removeWatchHistoryItem('site_b', 'skewed_item');
        await reopened.restoreWatchHistoryEntry(skewedRemote);
        final restoredPayload = reopened.exportSyncPayload();
        final restoredEntry = reopened
            .getWatchHistory()
            .firstWhere((e) => e.id == 'skewed_item');
        await reopened.removeWatchHistoryItem('site_b', 'skewed_item');
        final tombs =
            (jsonDecode(reopened.exportSyncPayload()) as Map)['tombstones']
                as Map;
        final delRev = (tombs['hist:site_b\nskewed_item'] as num).toInt();
        expect(delRev, greaterThan(restoredEntry.updated));

        // Merging the older restored snapshot MUST NOT resurrect the re-deleted item.
        await reopened.mergeSyncPayload(restoredPayload);
        expect(
          reopened.getWatchHistory().where((e) => e.id == 'skewed_item'),
          isEmpty,
        );
      },
    );

    test(
      'R2 P1-6: UC and Baidu canonical account identity survives cookie reorder/rotation while rejecting account switch',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        var ucCred = '__pus=review_account_A; theme=light';
        var baiduCred = 'BDUSS=baidu_acc_A; STOKEN=tok1';

        final httpClient = MockClient((req) async {
          if (req.url.host == 'pc-api.uc.cn') {
            final data = req.url.path.endsWith('/file/sort')
                ? <String, dynamic>{
                    'list': [
                      {
                        'fid': 'uc_vid_1',
                        'file_name': 'UC_Film.mp4',
                        'dir': false,
                        'file_type': 1,
                        'category': 1,
                        'size': 2048,
                      },
                    ],
                  }
                : <String, dynamic>{};
            return http.Response(
              jsonEncode({
                'status': 200,
                'code': 0,
                'data': data,
                'metadata': {'_total': 1},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'errno': 0,
              'has_more': 0,
              'list': [
                {
                  'fs_id': 9001,
                  'server_filename': 'Baidu_Film.mp4',
                  'path': '/Baidu_Film.mp4',
                  'isdir': 0,
                  'category': 1,
                  'size': 4096,
                },
              ],
            }),
            200,
          );
        });

        final client = PersonalCloudDriveClient(
          credentialReader: (provider) async =>
              provider == 'uc' ? ucCred : baiduCred,
          httpClient: httpClient,
        );
        addTearDown(client.close);

        // UC: create -> reorder cookies & rotate non-identity cookie -> same library & deduplicated.
        final ucInitial = await PersonalCloudLibrary.create(
          client: client,
          provider: PersonalCloudProvider.uc,
          folderId: '0',
          folderName: 'Movies',
          group: '网盘',
          isPrivate: false,
        );
        final ucSiteJson =
            (jsonDecode(ucInitial.entry.rawContent)['sites'] as List).single
                as Map;
        final ucSite = CmsSite(
          key: ucSiteJson['key'] as String,
          name: ucSiteJson['name'] as String,
          type: 1,
          api: ucSiteJson['api'] as String,
        );
        final ucLib = await PersonalCloudLibrary.open(ucSite, client: client);
        expect((await ucLib.home()).$2.videos.single.title, contains('UC_Film'));

        ucCred = 'theme=dark; __puus=ephemeral_1; __pus=review_account_A';
        final ucAgain = await PersonalCloudLibrary.create(
          client: client,
          provider: PersonalCloudProvider.uc,
          folderId: '0',
          folderName: 'Movies',
          group: '网盘',
          isPrivate: false,
        );
        expect(ucAgain.entry.id, ucInitial.entry.id);
        expect(ucAgain.updatedExisting, isTrue);
        expect((await ucLib.home()).$2.videos.single.title, contains('UC_Film'));

        // UC: genuine account switch MUST reject with account_mismatch.
        ucCred = '__pus=review_account_B; theme=light';
        await expectLater(
          ucLib.home(),
          throwsA(
            isA<PersonalCloudException>()
                .having((e) => e.code, 'code', 'account_mismatch'),
          ),
        );

        // Baidu: reorder & rotate STOKEN -> same library; switch BDUSS -> account_mismatch.
        final bdInitial = await PersonalCloudLibrary.create(
          client: client,
          provider: PersonalCloudProvider.baidu,
          folderId: '/',
          folderName: 'Videos',
          group: '网盘',
          isPrivate: false,
        );
        final bdSiteJson =
            (jsonDecode(bdInitial.entry.rawContent)['sites'] as List).single
                as Map;
        final bdSite = CmsSite(
          key: bdSiteJson['key'] as String,
          name: bdSiteJson['name'] as String,
          type: 1,
          api: bdSiteJson['api'] as String,
        );
        final bdLib = await PersonalCloudLibrary.open(bdSite, client: client);
        baiduCred = 'STOKEN=rotated_tok2; BDUSS=baidu_acc_A';
        final bdAgain = await PersonalCloudLibrary.create(
          client: client,
          provider: PersonalCloudProvider.baidu,
          folderId: '/',
          folderName: 'Videos',
          group: '网盘',
          isPrivate: false,
        );
        expect(bdAgain.entry.id, bdInitial.entry.id);
        expect(bdAgain.updatedExisting, isTrue);
        expect((await bdLib.home()).$2.videos.single.title, contains('Baidu_Film'));

        baiduCred = 'BDUSS=baidu_acc_B; STOKEN=tok3';
        await expectLater(
          bdLib.home(),
          throwsA(
            isA<PersonalCloudException>()
                .having((e) => e.code, 'code', 'account_mismatch'),
          ),
        );
      },
    );

    testWidgets(
      'R2 P2-2: Live portrait companion renders without overflow on 320x568 at 2.0x text scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final fakePlayer = _SilentFakePlayer();
        addTearDown(fakePlayer.dispose);

        final ch1 = LiveChannel(
          name: 'CCTV-1 综合高清频道',
          group: '央视频道',
          urls: const [
            'https://live.example/cctv1-a.m3u8',
            'https://live.example/cctv1-b.m3u8',
          ],
          health: LiveStreamHealth.fast,
          latencyMs: 120,
        );
        final groups = [
          LiveGroup(name: '央视频道', channels: [ch1]),
          LiveGroup(name: '卫视频道', channels: [ch1]),
        ];
        const liveSite = CmsSite(
          key: 'live_r2',
          name: '直播测试',
          type: 1,
          api: 'https://live.example/list.m3u',
        );
        final liveVideo = CmsVideo(
          id: ch1.name,
          title: ch1.name,
          lines: [CmsLine(name: ch1.group, episodes: ch1.episodes)],
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: PlayerScreen(
              site: liveSite,
              video: liveVideo,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              isLive: true,
              liveGroups: groups,
              initialLiveChannel: ch1,
              debugPlayer: fakePlayer,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R2 P2-3: Hardware Escape dismisses IosPressSlideMenuAnchor without popping underlying route and restores focus',
      (tester) async {
        tester.view.physicalSize = const Size(768, 1024);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final anchorFocus = FocusNode();
        addTearDown(anchorFocus.dispose);
        var selectedCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('底层专题页'),
                    Focus(
                      focusNode: anchorFocus,
                      child: IosPressSlideMenuAnchor(
                        openOnTap: true,
                        itemsBuilder: () => const [
                          IosSlideMenuAction(id: 'home', title: '返回首页'),
                          IosSlideMenuAction(id: 'live', title: '前往直播'),
                        ],
                        onSelected: (_) => selectedCount++,
                        child: const Text('快捷菜单入口'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        anchorFocus.requestFocus();
        await tester.pump();
        expect(anchorFocus.hasFocus, isTrue);

        await tester.tap(find.text('快捷菜单入口'));
        await tester.pumpAndSettle();
        expect(find.text('返回首页'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.text('返回首页'), findsNothing);
        expect(find.text('底层专题页'), findsOneWidget);
        expect(selectedCount, 0);
        expect(anchorFocus.hasFocus, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R3 P1-1: AVPlayer short 1s resume landing does not confirm early, and rejected 45s seek falls back to real playback confirmation',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<List<int>> runScenario({
          required int initialPositionMs,
          required bool seekSucceeds,
          required int tick1Ms,
          required int tick2Ms,
        }) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          int? openedMediaId;
          Future<void> emitAvEvent(Map<String, Object?> payload) async {
            final encoded = const StandardMethodCodec().encodeSuccessEnvelope(
              <String, Object?>{
                if (openedMediaId != null) 'mediaId': openedMediaId,
                ...payload,
              },
            );
            await messenger.handlePlatformMessage(
              IosAvPlayerController.defaultEventChannel.name,
              encoded,
              (_) {},
            );
          }

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': true,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  openedMediaId = (call.arguments as Map)['mediaId'] as int?;
                  return true;
                case 'seek':
                  return seekSucceeds;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );
          try {
            const site = CmsSite(
              key: 's_r3_seek',
              name: '测试源',
              type: 1,
              api: 'https://fixture.example/api',
            );
            const video = CmsVideo(
              id: 'vid_r3_seek',
              title: 'R3续播确认测试',
              lines: [
                CmsLine(
                  id: 'line_a',
                  name: '线路A',
                  episodes: [
                    CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                  ],
                ),
              ],
            );
            var confirmCount = 0;
            final avCtrl = IosAvPlayerController(
              platformOverride: TargetPlatform.iOS,
              isOhosOverride: false,
              isWebOverride: false,
            );
            final fakePlayer = _SilentFakePlayer();
            try {
              await tester.pumpWidget(
                MaterialApp(
                  home: PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    initialPositionMs: initialPositionMs,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                    onPlaybackConfirmed: (_) => confirmCount++,
                  ),
                ),
              );
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 120)),
              );
              await tester.pump(const Duration(milliseconds: 100));
              expect(openedMediaId, isNotNull);

              await emitAvEvent(<String, Object?>{
                'type': 'ready',
                'positionMs': 0,
                'durationMs': 1800000,
                'width': 1920,
                'height': 1080,
              });
              await emitAvEvent(<String, Object?>{
                'type': 'playbackState',
                'playing': true,
                'buffering': false,
                'positionMs': 0,
                'durationMs': 1800000,
              });
              await tester.pump();
              final before = confirmCount;

              await emitAvEvent(<String, Object?>{
                'type': 'progress',
                'playing': true,
                'positionMs': tick1Ms,
                'durationMs': 1800000,
              });
              await tester.pump();
              final afterTick1 = confirmCount;

              await emitAvEvent(<String, Object?>{
                'type': 'progress',
                'playing': true,
                'positionMs': tick2Ms,
                'durationMs': 1800000,
              });
              await tester.pump();
              final afterTick2 = confirmCount;

              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump(const Duration(milliseconds: 650));
              return [before, afterTick1, afterTick2];
            } finally {
              await fakePlayer.dispose();
            }
          } finally {
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
          }
        }

        // Scenario 1: Short 1s resume (0 -> 1000 -> 1250ms) must be [0, 0, 1].
        expect(
          await runScenario(
            initialPositionMs: 1000,
            seekSucceeds: true,
            tick1Ms: 1000,
            tick2Ms: 1250,
          ),
          [0, 0, 1],
        );

        // Scenario 2: Rejected 45s seek (false) falls back to real clock (0 -> 250 -> 1000ms).
        final failedSeekCounts = await runScenario(
          initialPositionMs: 45000,
          seekSucceeds: false,
          tick1Ms: 250,
          tick2Ms: 1000,
        );
        expect(failedSeekCounts.first, 0);
        expect(failedSeekCounts.last, 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R3 P1-3 & P1-4: Background self-heal flush cannot resurrect cleared history, and valid backup recovers corrupted local history',
      () async {
        // P1-3: Gated prefs-fallback self-heal flush serialized against clearWatchHistory().
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final disk = _GatedHistoryFileStore();
        Future<StorageService> openStorage() => StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );
        final storage = await openStorage();
        await storage.upsertWatchHistory(
          const WatchHistoryEntry(
            site: 'site_r3',
            id: 'previous',
            title: '旧磁盘记录',
            updated: 100,
          ),
          immediate: true,
          triggerSync: false,
        );
        const imported = WatchHistoryEntry(
          site: 'site_r3',
          id: 'imported',
          title: '待恢复记录',
          updated: 300,
        );
        final backup = CmsParser.encodeBackupPayload(
          origin: '',
          rawConfig:
              '{"sites":[{"key":"site_r3","name":"测试源","type":1,"api":"https://fixture.example/api"}]}',
          settings: <String, dynamic>{
            'watch_history': <Map<String, dynamic>>[imported.toJson()],
          },
        );
        disk.rejectHistoryWrites = true;
        await storage.importBackupJson(backup);
        disk.rejectHistoryWrites = false;

        final reopened = await openStorage();
        disk.firstWriteStarted = Completer<void>();
        disk.allowFirstWrite = Completer<void>();
        // Trigger prefs fallback read + background self-heal flush.
        expect(reopened.getWatchHistory().map((e) => e.id).toList(), ['imported']);
        await disk.firstWriteStarted!.future;

        final clearFuture = reopened.clearWatchHistory();
        disk.allowFirstWrite!.complete();
        await clearFuture;

        expect(reopened.getWatchHistory(), isEmpty);
        final afterRestart = await openStorage();
        expect(afterRestart.getWatchHistory(), isEmpty);

        // P1-4: Valid backup import recovers from corrupted watch_history.json.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final corruptDisk = InMemoryStorageFileStore();
        corruptDisk.writeBytesSync('watch_history.json', utf8.encode('{not-json'));
        Future<StorageService> openCorrupt() => StorageService.init(
              fileStore: corruptDisk,
              secureStore: InMemorySecureCredentialStore(),
            );
        final corrupted = await openCorrupt();
        expect(corrupted.getWatchHistory(), isEmpty);
        expect(corrupted.historyCorruptionNotifier.value, isTrue);

        await corrupted.importBackupJson(backup);
        expect(corrupted.historyCorruptionNotifier.value, isFalse);
        expect(corrupted.getWatchHistory().map((e) => e.id).toList(), ['imported']);

        final recovered = await openCorrupt();
        expect(recovered.historyCorruptionNotifier.value, isFalse);
        expect(recovered.getWatchHistory().map((e) => e.id).toList(), ['imported']);
      },
    );

    test(
      'R3 P1-5 & P2-6: Baidu/UC owner-ID listings resolve cleanly, tampered foreign URLs reject, and legacy UC libraries migrate and deduplicate',
      () async {
        // P1-5: Both Baidu and UC with listing owner IDs present resolve playable files.
        for (final provider in [
          PersonalCloudProvider.baidu,
          PersonalCloudProvider.uc,
        ]) {
          for (final includeOwnerId in [false, true]) {
            SharedPreferences.setMockInitialValues(<String, Object>{});
            final cred = provider == PersonalCloudProvider.baidu
                ? 'BDUSS=bd_owner_A; STOKEN=s1'
                : '__pus=uc_owner_A; theme=light';
            final mockHttp = MockClient((req) async {
              if (provider == PersonalCloudProvider.baidu) {
                if (req.url.path == '/api/filemetas') {
                  return http.Response(
                    jsonEncode({
                      'errno': 0,
                      'info': [
                        {
                          'fs_id': 777,
                          'dlink': 'https://d.pcs.baidu.com/file/ok?sign=1',
                          'size': 2048,
                        },
                      ],
                    }),
                    200,
                  );
                }
                return http.Response(
                  jsonEncode({
                    'errno': 0,
                    'has_more': 0,
                    if (includeOwnerId) 'uk': 42001,
                    'list': [
                      {
                        'fs_id': 777,
                        'server_filename': 'Sample.mp4',
                        'path': '/Sample.mp4',
                        'isdir': 0,
                        'category': 1,
                        'size': 2048,
                      },
                    ],
                  }),
                  200,
                );
              } else {
                if (req.url.path.endsWith('/file/download')) {
                  return http.Response(
                    jsonEncode({
                      'status': 200,
                      'code': 0,
                      'data': [
                        {
                          'fid': 'uc_f1',
                          'download_url': 'https://dl.uc.cn/v/ok.mp4',
                          'size': 2048,
                        },
                      ],
                    }),
                    200,
                  );
                }
                return http.Response(
                  jsonEncode({
                    'status': 200,
                    'code': 0,
                    'data': {
                      if (includeOwnerId) 'uid': 'uc_uid_900',
                      'list': [
                        {
                          'fid': 'uc_f1',
                          'file_name': 'Sample.mp4',
                          'dir': false,
                          'file_type': 1,
                          'category': 1,
                          'size': 2048,
                        },
                      ],
                    },
                    'metadata': {'_total': 1},
                  }),
                  200,
                );
              }
            });
            final client = PersonalCloudDriveClient(
              credentialReader: (_) async => cred,
              httpClient: mockHttp,
              mediaClientFactory: () =>
                  MockClient((_) async => http.Response('ok', 200)),
            );
            addTearDown(client.close);

            final created = await PersonalCloudLibrary.create(
              client: client,
              provider: provider,
              folderId: provider.rootFolderId,
              folderName: 'Videos',
              group: '网盘',
              isPrivate: false,
            );
            final siteMap =
                (jsonDecode(created.entry.rawContent)['sites'] as List).single
                    as Map;
            final lib = await PersonalCloudLibrary.open(
              CmsSite(
                key: siteMap['key'] as String,
                name: siteMap['name'] as String,
                type: 1,
                api: siteMap['api'] as String,
              ),
              client: client,
            );
            final (_, listing) = await lib.home();
            final ep = listing.videos.single.lines.single.episodes.single;
            final resolved = await lib.resolve(ep);
            expect(resolved.url, isNotEmpty);
            final dynamic lease = resolved.playbackSession['cloudMediaLease'];
            if (lease != null) {
              await lease.close();
            }

            // Tampered foreign cookie-account URL must still be rejected.
            final tamperedUri = Uri.parse(ep.url).replace(
              queryParameters: {
                ...Uri.parse(ep.url).queryParameters,
                'account': '${provider.key}:v2:foreign_other_account',
              },
            );
            await expectLater(
              lib.resolve(CmsEpisode(name: ep.name, url: tamperedUri.toString())),
              throwsA(
                isA<PersonalCloudException>()
                    .having((e) => e.code, 'code', 'account_mismatch'),
              ),
            );
          }
        }

        // P2-6: Pre-migration legacy UC library opens, migrates, deduplicates, and survives cookie reorder.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        var ucCred = '__pus=legacy_acc_1; theme=light';
        final legacyAccountId =
            sha256.convert(utf8.encode('uc|$ucCred')).toString().substring(0, 16);
        final legacyKey = PersonalCloudLibrary.deterministicKey(
          provider: PersonalCloudProvider.uc,
          accountId: legacyAccountId,
          driveId: '',
          folderId: '0',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'cloudlib.account.$legacyKey',
          jsonEncode({
            'provider': 'uc',
            'folderId': '0',
            'folderName': 'LegacyUC',
            'driveId': '',
            'accountId': legacyAccountId,
          }),
        );
        final ucHttp = MockClient((req) async {
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'data': {
                'list': [
                  {
                    'fid': 'clip_1',
                    'file_name': 'Clip.mp4',
                    'dir': false,
                    'file_type': 1,
                    'category': 1,
                    'size': 1024,
                  },
                ],
              },
              'metadata': {'_total': 1},
            }),
            200,
          );
        });
        final ucClient = PersonalCloudDriveClient(
          credentialReader: (_) async => ucCred,
          httpClient: ucHttp,
        );
        addTearDown(ucClient.close);

        final legacySite = CmsSite(
          key: 'cloudlib_$legacyKey',
          name: 'UC · LegacyUC',
          type: 1,
          api: '${PersonalCloudLibrary.prefix}$legacyKey',
        );
        final legacyLib = await PersonalCloudLibrary.open(
          legacySite,
          client: ucClient,
        );
        expect((await legacyLib.home()).$2.videos.single.title, contains('Clip'));

        final readded = await PersonalCloudLibrary.create(
          client: ucClient,
          provider: PersonalCloudProvider.uc,
          folderId: '0',
          folderName: 'LegacyUC',
          group: '网盘',
          isPrivate: false,
        );
        expect(readded.entry.id, 'cloudlib_$legacyKey');
        expect(readded.updatedExisting, isTrue);

        ucCred = 'theme=dark; __pus=legacy_acc_1';
        final reopenedLib = await PersonalCloudLibrary.open(
          legacySite,
          client: ucClient,
        );
        expect((await reopenedLib.home()).$2.videos.single.title, contains('Clip'));
      },
    );

    testWidgets(
      'R3 P2-7: Second PiP tap during willStart cancels pending PiP instead of re-starting, and stops on didStart',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        int? openedMediaId;
        var starts = 0;
        var stops = 0;
        var active = false;

        Future<void> emitAvEvent(Map<String, Object?> payload) async {
          final encoded = const StandardMethodCodec().encodeSuccessEnvelope(
            <String, Object?>{
              if (openedMediaId != null) 'mediaId': openedMediaId,
              ...payload,
            },
          );
          await messenger.handlePlatformMessage(
            IosAvPlayerController.defaultEventChannel.name,
            encoded,
            (_) {},
          );
        }

        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            switch (call.method) {
              case 'getTelemetry':
                return <String, Object?>{
                  'thermalState': 'nominal',
                  'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                  'isPipSupported': true,
                  'isPipPossible': true,
                  'isPipActive': active,
                  'systemVolume': 0.5,
                  'isAirPlayActive': false,
                };
              case 'open':
                openedMediaId = (call.arguments as Map)['mediaId'] as int?;
                return true;
              case 'startPip':
                starts++;
                return true;
              case 'stopPip':
                stops++;
                active = false;
                unawaited(
                  emitAvEvent(<String, Object?>{
                    'type': 'pipStateChanged',
                    'active': false,
                    'supported': true,
                    'possible': true,
                    'phase': 'didStop',
                  }),
                );
                return null;
              default:
                return null;
            }
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        const site = CmsSite(
          key: 's_r3_pip_cancel',
          name: '测试源',
          type: 1,
          api: 'https://fixture.example/api',
        );
        const video = CmsVideo(
          id: 'vid_r3_pip_cancel',
          title: '取消启动中画中画',
          lines: [
            CmsLine(
              id: 'line_a',
              name: '线路A',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
              ],
            ),
          ],
        );
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();
        addTearDown(fakePlayer.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final pipBtn = find.byKey(const Key('ios-vod-companion-pip-btn'));
        await tester.ensureVisible(pipBtn);
        await tester.tap(pipBtn);
        await tester.pump();
        expect(starts, 1);

        // Native enters willStart; user taps PiP again to cancel.
        await emitAvEvent(<String, Object?>{
          'type': 'pipStateChanged',
          'active': false,
          'supported': true,
          'possible': true,
          'phase': 'willStart',
        });
        await tester.pump();
        expect(avCtrl.isPipStarting, isTrue);

        await tester.tap(pipBtn);
        await tester.pump();
        expect(starts, 1);

        // Native finishes starting -> PlayerScreen must stop it immediately.
        active = true;
        await emitAvEvent(<String, Object?>{
          'type': 'pipStateChanged',
          'active': true,
          'supported': true,
          'possible': true,
          'phase': 'didStart',
        });
        await tester.pump(const Duration(milliseconds: 50));

        expect(starts, 1);
        expect(stops, 1);
        expect(avCtrl.isPipActive, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R3 P2-8: Rejected volume write readback during a held gesture reconciles baseline before next identical drag',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final storage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final writes = <double>[];

        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            switch (call.method) {
              case 'getTelemetry':
                return <String, Object?>{
                  'thermalState': 'nominal',
                  'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                  'isPipSupported': true,
                  'isPipPossible': true,
                  'isPipActive': false,
                  'systemVolume': 0.02,
                  'isAirPlayActive': false,
                };
              case 'getSystemVolume':
                return 0.02;
              case 'setSystemVolume':
                final v = (call.arguments as num).toDouble().clamp(0.0, 1.0);
                writes.add(v);
                return <String, Object?>{
                  'applied': true,
                  'volume': v,
                  'observedVolume': 0.02,
                };
              case 'open':
                return true;
              default:
                return null;
            }
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        const site = CmsSite(
          key: 's_r3_vol',
          name: '测试源',
          type: 1,
          api: 'https://fixture.example/api',
        );
        const video = CmsVideo(
          id: 'vid_r3_vol',
          title: '系统音量回读测试',
          lines: [
            CmsLine(
              id: 'line_a',
              name: '线路A',
              episodes: [
                CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
              ],
            ),
          ],
        );
        final avCtrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final fakePlayer = _SilentFakePlayer();
        addTearDown(fakePlayer.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreen(
              site: site,
              video: video,
              initialLineIndex: 0,
              initialEpisodeIndex: 0,
              storage: storage,
              debugPlayer: fakePlayer,
              debugIosAvPlayerController: avCtrl,
              debugVideoSurface: const ColoredBox(color: Colors.black),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        Future<double> dragUpOnRightSide() async {
          writes.clear();
          final g = await tester.startGesture(const Offset(700, 260));
          await g.moveBy(const Offset(0, -25));
          await tester.pump();
          await g.moveBy(const Offset(0, -50));
          await tester.pump(const Duration(milliseconds: 20));
          await g.up();
          await tester.pump(const Duration(milliseconds: 50));
          expect(tester.takeException(), isNull);
          return writes.last;
        }

        final firstLast = await dragUpOnRightSide();
        final secondLast = await dragUpOnRightSide();
        expect(secondLast, closeTo(firstLast, 0.005));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 650));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R4 P1-1 & P2-1: Non-clock PiP notification during pending seek never confirms landing early, and resume toast binds strictly to seek success',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<({List<int> counts, int resumeToastCount})> runResumeCase({
          required bool emitPipDuringSeek,
          required bool seekSucceeds,
          bool switchEpisodeBeforeLateReply = false,
        }) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final seekReply = Completer<bool>();
          var seekCalls = 0;

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': false,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  seekCalls++;
                  if (seekCalls == 1) return seekReply.future;
                  return true;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          const site = CmsSite(
            key: 's_r4_seek',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r4_seek',
            title: 'R4续播与提示测试',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                  CmsEpisode(name: '第2集', url: 'https://cdn.example/ep2.m3u8'),
                ],
              ),
            ],
          );
          var confirmCount = 0;
          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: PlayerScreen(
                  site: site,
                  video: video,
                  initialLineIndex: 0,
                  initialEpisodeIndex: 0,
                  initialPositionMs: 45000,
                  storage: storage,
                  debugPlayer: fakePlayer,
                  debugIosAvPlayerController: avCtrl,
                  debugVideoSurface: const ColoredBox(color: Colors.black),
                  onPlaybackConfirmed: (_) => confirmCount++,
                ),
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
            final mid = avCtrl.currentMediaId;
            expect(mid, isNotNull);

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            expect(seekCalls, 1);

            if (emitPipDuringSeek) {
              avCtrl.handleNativeEvent(const <Object?, Object?>{
                'type': 'pipStateChanged',
                'supported': true,
                'possible': true,
                'active': false,
              });
              await tester.pump();
            }

            if (switchEpisodeBeforeLateReply) {
              final ep2 = find.byKey(const Key('ios-portrait-episode-1'));
              for (var i = 0; i < 8 && ep2.evaluate().isEmpty; i++) {
                await tester.dragFrom(const Offset(190, 700), const Offset(0, -200));
                await tester.pump();
              }
              await tester.ensureVisible(ep2);
              await tester.tap(ep2);
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)),
              );
              await tester.pump(const Duration(milliseconds: 100));
              seekReply.complete(true);
              await tester.pump();
              final staleToast = find.textContaining('已为您续播至').evaluate().length;
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump(const Duration(milliseconds: 650));
              return (counts: [0, 0, 0], resumeToastCount: staleToast);
            }

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            final before = confirmCount;

            seekReply.complete(seekSucceeds);
            await tester.pump();

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': seekSucceeds ? 45000 : 250,
            });
            await tester.pump();
            final landing = confirmCount;

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': seekSucceeds ? 45250 : 1000,
            });
            await tester.pump();
            final progressed = confirmCount;
            final toastCount = find.textContaining('已为您续播至').evaluate().length;

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 650));
            return (
              counts: [before, landing, progressed],
              resumeToastCount: toastCount,
            );
          } finally {
            await fakePlayer.dispose();
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
          }
        }

        // P1-1: PiP notification while seek is pending yields [0, 0, 1] + valid toast on success.
        final withPip = await runResumeCase(
          emitPipDuringSeek: true,
          seekSucceeds: true,
        );
        expect(withPip.counts, [0, 0, 1]);
        expect(withPip.resumeToastCount, 1);

        // Positive control without intervening PiP notification.
        final control = await runResumeCase(
          emitPipDuringSeek: false,
          seekSucceeds: true,
        );
        expect(control.counts, [0, 0, 1]);
        expect(control.resumeToastCount, 1);

        // P2-1: Rejected seek must NOT show '已为您续播至', and still confirms real playback.
        final rejected = await runResumeCase(
          emitPipDuringSeek: false,
          seekSucceeds: false,
        );
        expect(rejected.counts.first, 0);
        expect(rejected.counts.last, 1);
        expect(rejected.resumeToastCount, 0);

        // P2-1: Late seek reply arriving after episode switch must NOT show stale resume toast.
        final lateAfterSwitch = await runResumeCase(
          emitPipDuringSeek: false,
          seekSucceeds: true,
          switchEpisodeBeforeLateReply: true,
        );
        expect(lateAfterSwitch.resumeToastCount, 0);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R4 P1-3 & P2-2: Failed dual/partial history backup rolls back cleanly, and quarantine retries before overwriting',
      () async {
        const previous = WatchHistoryEntry(
          site: 'site_r4',
          id: 'previous',
          title: '原有历史',
          updated: 100,
        );
        const imported = WatchHistoryEntry(
          site: 'site_r4',
          id: 'imported',
          title: '导入历史',
          updated: 200,
        );
        const third = WatchHistoryEntry(
          site: 'site_r4',
          id: 'third',
          title: '后续观看',
          updated: 300,
        );
        final backup = CmsParser.encodeBackupPayload(
          origin: '',
          rawConfig:
              '{"sites":[{"key":"site_r4","name":"测试源","type":1,"api":"https://fixture.example/api"}]}',
          settings: <String, dynamic>{
            'watch_history': <Map<String, dynamic>>[imported.toJson()],
          },
        );
        Future<StorageService> open(InMemoryStorageFileStore disk) =>
            StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );

        // P2-2: Transient unreadable history file retries quarantine before overwrite.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final qDisk = _TransientReadLockFileStore();
        final qInit = await open(qDisk);
        await qInit.upsertWatchHistory(
          previous,
          immediate: true,
          triggerSync: false,
        );
        final origBytes = qDisk.readBytesSync('watch_history.json');
        qDisk.readLocked = true;
        final qLocked = await open(qDisk);
        expect(qLocked.getWatchHistory(), isEmpty);
        expect(qLocked.isHistoryCorrupted, isTrue);

        // While still unreadable, import MUST refuse to overwrite original file.
        await expectLater(qLocked.importBackupJson(backup), throwsA(isA<StateError>()));
        qDisk.readLocked = false;
        expect(qDisk.readBytesSync('watch_history.json'), origBytes);

        // Once readability returns, import quarantines exact original bytes and succeeds.
        final restoredCfg = await qLocked.importBackupJson(backup);
        expect(restoredCfg, isNotNull);
        expect(qLocked.getWatchHistory().map((e) => e.id).toList(), ['imported']);
        final archives = qDisk
            .listFileNamesSync()
            .where((f) => f.startsWith('watch_history_corrupt_'))
            .toList();
        expect(archives, isNotEmpty);
        expect(
          archives.any(
            (f) => jsonEncode(qDisk.readBytesSync(f)) == jsonEncode(origBytes),
          ),
          isTrue,
        );

        // P1-3 (a): Dual write failure (disk throws + prefs throws PlatformException) rolls back memory.
        final prevPlatform = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = prevPlatform);

        SharedPreferences.setMockInitialValues(<String, Object>{});
        final failPrefs = _FailingHistoryPrefsStore();
        SharedPreferencesStorePlatform.instance = failPrefs;
        final dualDisk = _TransientReadLockFileStore();
        final dualInst = await open(dualDisk);
        await dualInst.upsertWatchHistory(
          previous,
          immediate: true,
          triggerSync: false,
        );
        dualDisk.rejectHistoryWrites = true;
        failPrefs.throwOnHistoryMirror = true;
        await expectLater(
          dualInst.importBackupJson(backup),
          throwsA(isA<PlatformException>()),
        );
        expect(dualInst.getWatchHistory().map((e) => e.id).toList(), ['previous']);

        dualDisk.rejectHistoryWrites = false;
        failPrefs.throwOnHistoryMirror = false;
        await dualInst.upsertWatchHistory(
          third,
          immediate: true,
          triggerSync: false,
        );
        final afterDualRestart =
            (await open(dualDisk)).getWatchHistory().map((e) => e.id).toList();
        expect(afterDualRestart, containsAll(['third', 'previous']));
        expect(afterDualRestart, isNot(contains('imported')));

        // P1-3 (b): Refused pending-flush marker fails import and rolls back prefs/cache cleanly.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final markerPrefs = _FailingHistoryPrefsStore();
        SharedPreferencesStorePlatform.instance = markerPrefs;
        final markerDisk = _TransientReadLockFileStore();
        final markerInst = await open(markerDisk);
        await markerInst.upsertWatchHistory(
          previous,
          immediate: true,
          triggerSync: false,
        );
        markerDisk.rejectHistoryWrites = true;
        markerPrefs.refusePendingMarker = true;
        await expectLater(
          markerInst.importBackupJson(backup),
          throwsA(isA<StateError>()),
        );
        final reloadedPrefs = await SharedPreferences.getInstance();
        await reloadedPrefs.reload();
        expect(
          reloadedPrefs.getBool(StorageService.keyWatchHistoryPrefsPendingFlush),
          isNot(true),
        );
        markerDisk.rejectHistoryWrites = false;
        markerPrefs.refusePendingMarker = false;
        expect(
          (await open(markerDisk)).getWatchHistory().map((e) => e.id).toList(),
          ['previous'],
        );
      },
    );

    test(
      'R4 P1-4: UC and Baidu page 2 omitting optional owner ID never downgrades stored owner identity, while conflicting owner ID still rejects',
      () async {
        for (final provider in [
          PersonalCloudProvider.uc,
          PersonalCloudProvider.baidu,
        ]) {
          for (final omitPageTwoOwner in [false, true]) {
            SharedPreferences.setMockInitialValues(<String, Object>{});
            final isBaidu = provider == PersonalCloudProvider.baidu;
            var injectConflictingPageTwoOwner = false;
            final client = PersonalCloudDriveClient(
              credentialReader: (_) async =>
                  isBaidu ? 'BDUSS=r4_same' : '__pus=r4_same',
              mediaClientFactory: () =>
                  MockClient((_) async => http.Response('ok', 200)),
              httpClient: MockClient((req) async {
                final uri = req.url;
                final pageTwo = isBaidu
                    ? (int.tryParse(uri.queryParameters['start'] ?? '0') ?? 0) > 0
                    : uri.queryParameters['_page'] == '2';
                final id = pageTwo ? 124 : 123;
                final name = 'Clip-$id.mp4';
                if (!isBaidu && uri.path.endsWith('/file/download')) {
                  return http.Response(
                    jsonEncode({
                      'status': 200,
                      'code': 0,
                      'data': [
                        {'fid': '123', 'download_url': 'https://dl.uc.cn/c.mp4'},
                      ],
                    }),
                    200,
                  );
                }
                if (isBaidu && uri.path == '/api/filemetas') {
                  return http.Response(
                    jsonEncode({
                      'errno': 0,
                      'info': [
                        {
                          'fs_id': 123,
                          'dlink': 'https://d.pcs.baidu.com/file/123',
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (!isBaidu) {
                  if (!uri.path.endsWith('/file/sort')) {
                    return http.Response(
                      jsonEncode({'status': 200, 'code': 0, 'data': {}}),
                      200,
                    );
                  }
                  final uid = pageTwo
                      ? (injectConflictingPageTwoOwner
                          ? 'ownerB'
                          : (omitPageTwoOwner ? null : 'ownerA'))
                      : 'ownerA';
                  return http.Response(
                    jsonEncode({
                      'status': 200,
                      'code': 0,
                      'data': {
                        if (uid != null) 'uid': uid,
                        'list': [
                          {
                            'fid': '$id',
                            'file_name': name,
                            'dir': false,
                            'file_type': 1,
                            'category': 1,
                            'size': 1300,
                          },
                        ],
                      },
                      'metadata': {'_total': 51},
                    }),
                    200,
                  );
                }
                final uk = pageTwo
                    ? (injectConflictingPageTwoOwner
                        ? 888
                        : (omitPageTwoOwner ? null : 777))
                    : 777;
                return http.Response(
                  jsonEncode({
                    'errno': 0,
                    if (uk != null) 'uk': uk,
                    'has_more': pageTwo ? 0 : 1,
                    'list': [
                      {
                        'fs_id': id,
                        'server_filename': name,
                        'path': '/$name',
                        'isdir': 0,
                        'category': 1,
                        'size': 1300,
                      },
                    ],
                  }),
                  200,
                );
              }),
            );
            addTearDown(client.close);

            final saved = await PersonalCloudLibrary.create(
              client: client,
              provider: provider,
              folderId: provider.rootFolderId,
              folderName: 'Root',
              group: '网盘',
              isPrivate: false,
            );
            final siteJson =
                (jsonDecode(saved.entry.rawContent)['sites'] as List).single
                    as Map;
            final site = CmsSite(
              key: siteJson['key'] as String,
              name: 'Root',
              type: 1,
              api: siteJson['api'] as String,
            );
            final lib = await PersonalCloudLibrary.open(site, client: client);
            final firstListing = (await lib.home()).$2;
            final pageOneCard = firstListing.videos.single;
            final ownerBefore = lib.accountId;

            final pageTwoListing =
                await lib.list(provider.rootFolderId, '', 2);
            expect(pageTwoListing.videos.single.title, contains('124'));

            final reopened =
                await PersonalCloudLibrary.open(site, client: client);
            expect(reopened.accountId, ownerBefore);
            final detail = await reopened.detail(pageOneCard);
            final ep = await reopened.resolve(detail.lines.single.episodes.single);
            expect(ep.url, isNotEmpty);
            final dynamic lease = ep.playbackSession['cloudMediaLease'];
            if (lease != null) {
              await lease.close();
            }

            // Conflicting owner ID on page 2 MUST still reject with account_mismatch.
            injectConflictingPageTwoOwner = true;
            await expectLater(
              reopened.list(provider.rootFolderId, '', 2),
              throwsA(
                isA<PersonalCloudException>()
                    .having((e) => e.code, 'code', 'account_mismatch'),
              ),
            );
          }
        }
      },
    );

    test(
      'R5 P1-1 & P2-1: Disk commit agrees across memory/disk/cold-start when prefs mirror throws, and quarantine verifies exact current bytes',
      () async {
        const previous = WatchHistoryEntry(
          site: 'site_r5',
          id: 'previous',
          title: '旧历史',
          updated: 100,
        );
        const imported = WatchHistoryEntry(
          site: 'site_r5',
          id: 'imported',
          title: '导入历史',
          updated: 200,
        );
        const later = WatchHistoryEntry(
          site: 'site_r5',
          id: 'later',
          title: '新增历史',
          updated: 300,
        );
        String makeBackup(WatchHistoryEntry row) => CmsParser.encodeBackupPayload(
              origin: '',
              rawConfig:
                  '{"sites":[{"key":"site_r5","name":"测试源","type":1,"api":"https://fixture.example/api"}]}',
              settings: <String, dynamic>{
                'watch_history': <Map<String, dynamic>>[row.toJson()],
              },
            );
        Future<StorageService> open(InMemoryStorageFileStore disk) =>
            StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );

        final prevPlatform = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = prevPlatform);

        // P1-1: Primary disk commits while secondary prefs mirror throws ->
        // import succeeds and memory, disk, and cold restart ALL agree on [imported].
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final mirrorFailPrefs = _FailingHistoryPrefsStore();
        SharedPreferencesStorePlatform.instance = mirrorFailPrefs;
        final commitDisk = _TransientReadLockFileStore();
        final commitSvc = await open(commitDisk);
        await commitSvc.upsertWatchHistory(
          previous,
          immediate: true,
          triggerSync: false,
        );
        mirrorFailPrefs.throwOnHistoryMirror = true;
        final cfg = await commitSvc.importBackupJson(makeBackup(imported));
        expect(cfg, isNotNull);
        final memIds = commitSvc.getWatchHistory().map((e) => e.id).toList();
        final diskIds = (jsonDecode(
                  utf8.decode(commitDisk.readBytesSync('watch_history.json')),
                ) as List)
            .map((e) => (e as Map)['id'])
            .toList();
        mirrorFailPrefs.throwOnHistoryMirror = false;
        await (await SharedPreferences.getInstance()).reload();
        final coldIds =
            (await open(commitDisk)).getWatchHistory().map((e) => e.id).toList();
        expect(memIds, ['imported']);
        expect(diskIds, ['imported']);
        expect(coldIds, ['imported']);

        // P2-1 (a): Second incident following a prior recovered incident MUST
        // archive the exact current bytes rather than trusting the older archive.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final secondDisk = _TransientReadLockFileStore();
        secondDisk.writeBytesSync(
          'watch_history.json',
          utf8.encode('earlier malformed payload'),
        );
        final firstIncident = await open(secondDisk);
        expect(firstIncident.getWatchHistory(), isEmpty);
        expect(firstIncident.isHistoryCorrupted, isTrue);
        await firstIncident.importBackupJson(makeBackup(previous));
        await firstIncident.upsertWatchHistory(
          later,
          immediate: true,
          triggerSync: false,
        );
        final currentBytes = secondDisk.readBytesSync('watch_history.json');
        final currentText = utf8.decode(currentBytes);
        secondDisk.readLocked = true;
        final lockedSecond = await open(secondDisk);
        expect(lockedSecond.getWatchHistory(), isEmpty);
        expect(lockedSecond.isHistoryCorrupted, isTrue);
        secondDisk.readLocked = false;
        await lockedSecond.importBackupJson(makeBackup(imported));
        final archives = secondDisk
            .listFileNamesSync()
            .where((f) => f.startsWith('watch_history_corrupt_'))
            .toList();
        expect(archives.length, greaterThanOrEqualTo(2));
        expect(
          archives.any((f) => utf8.decode(secondDisk.readBytesSync(f)) == currentText),
          isTrue,
        );

        // P2-1 (b): Initial quarantine fails on BOTH file and async prefs ->
        // must NOT mark confirmed; later restore retries and preserves exact bytes.
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final unconfirmedPrefs = _FailingHistoryPrefsStore()
          ..throwOnQuarantinePrefs = true;
        SharedPreferencesStorePlatform.instance = unconfirmedPrefs;
        final unconfirmedDisk = _TransientReadLockFileStore()
          ..rejectQuarantineWrites = true;
        const corruptOriginal = 'unconfirmed-archive-original-bytes';
        unconfirmedDisk.writeBytesSync(
          'watch_history.json',
          utf8.encode(corruptOriginal),
        );
        final unconfirmedSvc = await open(unconfirmedDisk);
        expect(unconfirmedSvc.getWatchHistory(), isEmpty);
        expect(unconfirmedSvc.isHistoryCorrupted, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(
          unconfirmedDisk
              .listFileNamesSync()
              .where((f) => f.startsWith('watch_history_corrupt_')),
          isEmpty,
        );
        unconfirmedDisk.rejectQuarantineWrites = false;
        final recoveredCfg =
            await unconfirmedSvc.importBackupJson(makeBackup(imported));
        expect(recoveredCfg, isNotNull);
        final retryArchives = unconfirmedDisk
            .listFileNamesSync()
            .where((f) => f.startsWith('watch_history_corrupt_'))
            .toList();
        expect(
          retryArchives.any(
            (f) => utf8.decode(unconfirmedDisk.readBytesSync(f)) == corruptOriginal,
          ),
          isTrue,
        );
      },
    );

    test(
      'R5 P1-2: Re-adding UC/Baidu library preserves verified owner on direct key hit and never rebinds an existing owner to a distinct explicit owner',
      () async {
        for (final provider in [
          PersonalCloudProvider.uc,
          PersonalCloudProvider.baidu,
        ]) {
          final isBaidu = provider == PersonalCloudProvider.baidu;
          // (a) Direct-key hit with omitOnReadd preserves verified owner & card playability.
          SharedPreferences.setMockInitialValues(<String, Object>{});
          var sendOwner = false;
          var owner = 'A';
          var session = 'sess_A';
          final client = PersonalCloudDriveClient(
            credentialReader: (_) async =>
                isBaidu ? 'BDUSS=$session' : '__pus=$session',
            mediaClientFactory: () =>
                MockClient((_) async => http.Response('ok', 200)),
            httpClient: MockClient((req) async {
              final Map<String, Object?> body;
              if (req.url.path == '/1/clouddrive/file/sort') {
                body = {
                  'status': 200,
                  'code': 0,
                  'data': {
                    if (sendOwner) 'uid': owner,
                    'list': [
                      {
                        'fid': '123',
                        'file_name': 'Clip.mp4',
                        'dir': false,
                        'file_type': 1,
                        'category': 1,
                        'size': 1300,
                      },
                    ],
                  },
                  'metadata': {'_total': 1},
                };
              } else if (req.url.path == '/1/clouddrive/file/download') {
                body = {
                  'status': 200,
                  'code': 0,
                  'data': [
                    {'fid': '123', 'download_url': 'https://dl.uc.cn/c.mp4'},
                  ],
                };
              } else if (req.url.path == '/api/list') {
                body = {
                  'errno': 0,
                  if (sendOwner) 'uk': owner == 'A' ? 777 : 888,
                  'has_more': 0,
                  'list': [
                    {
                      'fs_id': 123,
                      'server_filename': 'Clip.mp4',
                      'path': '/Clip.mp4',
                      'isdir': 0,
                      'category': 1,
                      'size': 1300,
                    },
                  ],
                };
              } else if (req.url.path == '/api/filemetas') {
                body = {
                  'errno': 0,
                  'info': [
                    {'fs_id': 123, 'dlink': 'https://d.pcs.baidu.com/file/123'},
                  ],
                };
              } else {
                body = {'status': 200, 'code': 0, 'data': {}};
              }
              return http.Response(jsonEncode(body), 200);
            }),
          );
          addTearDown(client.close);

          Future<PersonalCloudLibrary> openEntry(SubscriptionEntry entry) async {
            final siteJson =
                (jsonDecode(entry.rawContent)['sites'] as List).single as Map;
            return PersonalCloudLibrary.open(
              CmsSite(
                key: siteJson['key'] as String,
                name: 'Root',
                type: 1,
                api: siteJson['api'] as String,
              ),
              client: client,
            );
          }

          final saved = await PersonalCloudLibrary.create(
            client: client,
            provider: provider,
            folderId: provider.rootFolderId,
            folderName: 'Root',
            group: '网盘',
            isPrivate: false,
          );
          sendOwner = true;
          final firstLib = await openEntry(saved.entry);
          final card = (await firstLib.home()).$2.videos.single;
          final verifiedOwner = firstLib.accountId;

          // Re-add while omitting optional owner (hits original deterministic key directly).
          sendOwner = false;
          final resaved = await PersonalCloudLibrary.create(
            client: client,
            provider: provider,
            folderId: provider.rootFolderId,
            folderName: 'Root',
            group: '网盘',
            isPrivate: false,
          );
          expect(resaved.updatedExisting, isTrue);
          expect(resaved.entry.id, saved.entry.id);
          final afterResave = await openEntry(saved.entry);
          expect(afterResave.accountId, verifiedOwner);
          final resolved = await afterResave.resolve(
            (await afterResave.detail(card)).lines.single.episodes.single,
          );
          expect(resolved.url, isNotEmpty);
          final dynamic lease = resolved.playbackSession['cloudMediaLease'];
          if (lease != null) await lease.close();

          // (b) Distinct explicit owner (even with same cookie) MUST create a
          // separate subscription key and NEVER overwrite owner A's binding.
          sendOwner = true;
          owner = 'B';
          final second = await PersonalCloudLibrary.create(
            client: client,
            provider: provider,
            folderId: provider.rootFolderId,
            folderName: 'Root',
            group: '网盘',
            isPrivate: false,
          );
          expect(second.entry.id, isNot(saved.entry.id));
          expect((await openEntry(saved.entry)).accountId, verifiedOwner);
        }
      },
    );

    testWidgets(
      'R5 P2-2: Rejected AVPlayer manual scrub and rejected auto-resume never write unconfirmed targets to watch history',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<({List<int> atRest, List<int> afterExit})> runScrubCase({
          required int initialProgressMs,
          required bool allowSeek,
        }) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          var seekCalls = 0;
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': false,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  seekCalls++;
                  return allowSeek;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );
          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          const site = CmsSite(
            key: 's_r5_scrub',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r5_scrub',
            title: '跳转历史测试',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );
          try {
            await tester.pumpWidget(
              MaterialApp(
                home: PlayerScreen(
                  site: site,
                  video: video,
                  initialLineIndex: 0,
                  initialEpisodeIndex: 0,
                  initialPositionMs: 0,
                  storage: storage,
                  debugPlayer: fakePlayer,
                  debugIosAvPlayerController: avCtrl,
                  debugVideoSurface: const ColoredBox(color: Colors.black),
                ),
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 200));
            final mid = avCtrl.currentMediaId;
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': mid,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': initialProgressMs,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': false,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': initialProgressMs,
            });
            await tester.pump();

            final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
            expect(slider, findsOneWidget);
            await tester.tap(slider);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(seekCalls, 1);

            final atRest = storage
                .getWatchHistory()
                .where((e) => e.id == video.id)
                .map((e) => e.position)
                .toList();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 650));
            final afterExit = storage
                .getWatchHistory()
                .where((e) => e.id == video.id)
                .map((e) => e.position)
                .toList();
            return (atRest: atRest, afterExit: afterExit);
          } finally {
            await fakePlayer.dispose();
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
          }
        }

        // Rejected scrub at 750ms and 12000ms must preserve actual native position.
        final rejectShort =
            await runScrubCase(initialProgressMs: 750, allowSeek: false);
        expect(rejectShort.atRest, [750]);
        expect(rejectShort.afterExit, [750]);

        final rejectLong =
            await runScrubCase(initialProgressMs: 12000, allowSeek: false);
        expect(rejectLong.atRest, [12000]);
        expect(rejectLong.afterExit, [12000]);

        // Positive control: accepted scrub persists target (~50000ms).
        final acceptLong =
            await runScrubCase(initialProgressMs: 12000, allowSeek: true);
        expect(acceptLong.atRest.single, greaterThan(40000));
        expect(acceptLong.afterExit.single, greaterThan(40000));

        // Rejected 45s auto-resume followed by exit at 750ms must save [750], never [45000].
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final resumeStorage = await StorageService.init(
          fileStore: InMemoryStorageFileStore(),
          secureStore: InMemorySecureCredentialStore(),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            switch (call.method) {
              case 'getTelemetry':
                return <String, Object?>{
                  'thermalState': 'nominal',
                  'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                  'isPipSupported': true,
                  'isPipPossible': false,
                  'isPipActive': false,
                  'systemVolume': 0.5,
                  'isAirPlayActive': false,
                };
              case 'open':
                return true;
              case 'seek':
                return false;
              default:
                return null;
            }
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        final resumeAv = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        final resumeFake = _SilentFakePlayer();
        try {
          const site = CmsSite(
            key: 's_r5_resume',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r5_resume',
            title: '续播拒绝退出测试',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );
          await tester.pumpWidget(
            MaterialApp(
              home: PlayerScreen(
                site: site,
                video: video,
                initialLineIndex: 0,
                initialEpisodeIndex: 0,
                initialPositionMs: 45000,
                storage: resumeStorage,
                debugPlayer: resumeFake,
                debugIosAvPlayerController: resumeAv,
                debugVideoSurface: const ColoredBox(color: Colors.black),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 200));
          final mid = resumeAv.currentMediaId;
          resumeAv.handleNativeEvent(<Object?, Object?>{
            'type': 'ready',
            'mediaId': mid,
            'durationMs': 100000,
            'positionMs': 0,
          });
          await tester.pump();
          resumeAv.handleNativeEvent(<Object?, Object?>{
            'type': 'playbackState',
            'mediaId': mid,
            'playing': true,
            'buffering': false,
            'durationMs': 100000,
            'positionMs': 0,
          });
          await tester.pump();
          resumeAv.handleNativeEvent(<Object?, Object?>{
            'type': 'progress',
            'mediaId': mid,
            'playing': true,
            'durationMs': 100000,
            'positionMs': 250,
          });
          await tester.pump();
          resumeAv.handleNativeEvent(<Object?, Object?>{
            'type': 'progress',
            'mediaId': mid,
            'playing': true,
            'durationMs': 100000,
            'positionMs': 750,
          });
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 650));
          expect(
            resumeStorage
                .getWatchHistory()
                .where((e) => e.id == video.id)
                .map((e) => e.position)
                .toList(),
            [750],
          );
        } finally {
          await resumeFake.dispose();
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'R6 P1-1 & P2-3: Failed backup import restores delayed history flush, rolls back whole bundle atomically on false/exception, and preserves malformed UTF-8 quarantine bytes',
      (tester) async {
        const cfg =
            '{"sites":[{"key":"f","name":"Fixture","type":1,"api":"https://fixture.example/api"}]}';
        const prevEntry = WatchHistoryEntry(
          site: 'f',
          id: 'previous',
          title: 'Previous',
          updated: 1,
        );
        const unsavedEntry = WatchHistoryEntry(
          site: 'f',
          id: 'unsaved',
          title: 'Unsaved',
          updated: 9,
        );
        const importedEntry = WatchHistoryEntry(
          site: 'f',
          id: 'imported',
          title: 'Imported',
          updated: 2,
        );

        String makeBackup({bool includeFavorites = false}) =>
            CmsParser.encodeBackupPayload(
              origin: '',
              rawConfig: cfg,
              settings: <String, dynamic>{
                StorageService.keyWatchHistory: [importedEntry.toJson()],
                if (includeFavorites)
                  StorageService.keyFavorites: [
                    {'site': 'f', 'id': 'newFav', 'title': 'New'},
                  ],
              },
            );

        // 1a. Delayed history flush timer survives failed backup import.
        final prevPlatform = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = prevPlatform);

        final timerStore = _R6SelectivePrefsStore();
        SharedPreferencesStorePlatform.instance = timerStore;
        await (await SharedPreferences.getInstance()).reload();
        final timerDisk = _R6RejectArchiveDisk();
        final timerStorage = await StorageService.init(
          fileStore: timerDisk,
          secureStore: InMemorySecureCredentialStore(),
        );
        await timerStorage.upsertWatchHistory(
          prevEntry,
          immediate: true,
          triggerSync: false,
        );
        await timerStorage.upsertWatchHistory(
          unsavedEntry,
          triggerSync: false,
        );
        expect(
          timerStorage.getWatchHistory().map((e) => e.id).toList(),
          contains('unsaved'),
        );
        timerStore.refuseOnceKey = 'flutter.${StorageService.keyHistoryCorrupted}';
        await expectLater(
          timerStorage.importBackupJson(makeBackup()),
          throwsStateError,
        );
        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        final timerPrefs = await SharedPreferences.getInstance();
        await timerPrefs.reload();
        final timerRestart = await StorageService.init(
          fileStore: timerDisk,
          secureStore: InMemorySecureCredentialStore(),
        );
        expect(
          timerRestart.getWatchHistory().map((e) => e.id).toList(),
          contains('unsaved'),
        );

        // 1b. Whole-bundle history + favorites atomicity when keyFavorites
        // returns false OR throws PlatformException, plus positive control.
        for (final mode in ['success', 'false', 'throw']) {
          final bundleStore = _R6SelectivePrefsStore();
          SharedPreferencesStorePlatform.instance = bundleStore;
          await (await SharedPreferences.getInstance()).reload();
          final bundleDisk = _R6RejectArchiveDisk();
          final s = await StorageService.init(
            fileStore: bundleDisk,
            secureStore: InMemorySecureCredentialStore(),
          );
          await s.upsertWatchHistory(
            prevEntry,
            immediate: true,
            triggerSync: false,
          );
          final p = await SharedPreferences.getInstance();
          await p.setString(
            StorageService.keyFavorites,
            jsonEncode([
              {'site': 'f', 'id': 'oldFav', 'title': 'Old'},
            ]),
          );
          if (mode == 'false') {
            bundleStore.refuseKey = 'flutter.${StorageService.keyFavorites}';
          } else if (mode == 'throw') {
            bundleStore.throwKey = 'flutter.${StorageService.keyFavorites}';
          }
          Object? err;
          try {
            await s.importBackupJson(makeBackup(includeFavorites: true));
          } catch (e) {
            err = e;
          }
          final memHist = s.getWatchHistory().map((e) => e.id).toList();
          final memFav = s.getFavorites().map((e) => e.id).toList();
          bundleStore.refuseKey = null;
          bundleStore.throwKey = null;
          await p.reload();
          final cold = await StorageService.init(
            fileStore: bundleDisk,
            secureStore: InMemorySecureCredentialStore(),
          );
          final coldHist = cold.getWatchHistory().map((e) => e.id).toList();
          final coldFav = cold.getFavorites().map((e) => e.id).toList();
          if (mode == 'success') {
            expect(err, isNull);
            expect(memHist, ['imported']);
            expect(coldHist, ['imported']);
            expect(memFav, ['newFav']);
            expect(coldFav, ['newFav']);
          } else {
            expect(err, isNotNull);
            expect(memHist, ['previous']);
            expect(coldHist, ['previous']);
            expect(memFav, ['oldFav']);
            expect(coldFav, ['oldFav']);
          }
        }

        // 2. Malformed UTF-8 bytes in corrupted watch_history.json cannot be
        // considered byte-exact via lossy prefs text; refuse overwrite while
        // disk stays unwritable, then archive exact bytes once writable.
        SharedPreferencesStorePlatform.instance = prevPlatform;
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final corruptDisk = _R6RejectArchiveDisk()..rejectArchives = true;
        final rawCorruptBytes = <int>[
          ...utf8.encode('[{"site":"f","title":"'),
          0xff,
        ];
        corruptDisk.writeBytesSync('watch_history.json', rawCorruptBytes);
        final corruptStorage = await StorageService.init(
          fileStore: corruptDisk,
          secureStore: InMemorySecureCredentialStore(),
        );
        expect(corruptStorage.getWatchHistory(), isEmpty);
        expect(corruptStorage.historyCorruptionNotifier.value, isTrue);
        await tester.pump();
        // Still unwritable: must refuse to overwrite watch_history.json.
        await expectLater(
          corruptStorage.importBackupJson(makeBackup()),
          throwsStateError,
        );
        expect(
          corruptDisk.readBytesSync('watch_history.json'),
          rawCorruptBytes,
        );
        // Once disk archive becomes writable, exact bytes are archived & restore succeeds.
        corruptDisk.rejectArchives = false;
        await corruptStorage.importBackupJson(makeBackup());
        final exactArchive = corruptDisk
            .listFileNamesSync()
            .where((k) => k.startsWith('watch_history_corrupt_'))
            .any(
              (k) =>
                  listEquals(corruptDisk.readBytesSync(k), rawCorruptBytes),
            );
        expect(exactArchive, isTrue);
        expect(
          corruptStorage.getWatchHistory().map((e) => e.id).toList(),
          ['imported'],
        );
      },
    );

    testWidgets(
      'R6 P2-4: Pending AVPlayer seek with Navigator pop and landscape ±15s both share confirmed playback clock',
      (tester) async {
        Future<({List<int> atRest, List<int> afterExit})> runAvCase({
          required Size viewSize,
          required int initialProgressMs,
          required String action, // 'scrub_nav_pending', 'scrub_nav_replied', 'center_reject', 'center_accept'
        }) async {
          tester.view.physicalSize = viewSize;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final pendingReply = Completer<bool>();
          int? lastSeekTarget;
          late IosAvPlayerController avCtrl;
          int? activeMediaId;

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': false,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  lastSeekTarget = (call.arguments as num).toInt();
                  if (action == 'center_accept') {
                    avCtrl.handleNativeEvent(<Object?, Object?>{
                      'type': 'progress',
                      'mediaId': activeMediaId,
                      'playing': false,
                      'durationMs': 100000,
                      'positionMs': lastSeekTarget,
                    });
                    return true;
                  }
                  if (action == 'center_reject') {
                    return false;
                  }
                  return pendingReply.future;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          final navKey = GlobalKey<NavigatorState>();
          const site = CmsSite(
            key: 's_r6_seek',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r6_seek',
            title: 'R6进度一致性测试',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );

          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                home: const Scaffold(body: Text('home')),
              ),
            );
            unawaited(
              navKey.currentState!.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump(const Duration(milliseconds: 200));

            activeMediaId = avCtrl.currentMediaId;
            expect(activeMediaId, isNotNull);
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': activeMediaId,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': activeMediaId,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': activeMediaId,
              'playing': true,
              'durationMs': 100000,
              'positionMs': initialProgressMs,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': activeMediaId,
              'playing': false,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': initialProgressMs,
            });
            await tester.pump();

            if (action.startsWith('center_')) {
              final fwd = find.byKey(const Key('player-center-forward'));
              expect(fwd, findsOneWidget);
              await tester.tap(fwd);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 250));
            } else {
              final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
              expect(slider, findsOneWidget);
              await tester.tap(slider);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 250));
              if (action == 'scrub_nav_replied') {
                pendingReply.complete(false);
                await tester.pump();
              }
            }

            final atRest = storage
                .getWatchHistory()
                .where((e) => e.id == video.id)
                .map((e) => e.position)
                .toList();

            await navKey.currentState!.maybePop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            if (!pendingReply.isCompleted) {
              pendingReply.complete(false);
              await tester.pump();
            }

            final afterExit = storage
                .getWatchHistory()
                .where((e) => e.id == video.id)
                .map((e) => e.position)
                .toList();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 200));
            return (atRest: atRest, afterExit: afterExit);
          } finally {
            await fakePlayer.dispose();
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
          }
        }

        // Order 1: Navigator pop while seek is still pending -> saves 12000, never 50000.
        final pendingNav = await runAvCase(
          viewSize: const Size(390, 844),
          initialProgressMs: 12000,
          action: 'scrub_nav_pending',
        );
        expect(pendingNav.atRest, [12000]);
        expect(pendingNav.afterExit, [12000]);

        // Order 2: Seek rejection arrives before Navigator pop -> saves 12000.
        final repliedNav = await runAvCase(
          viewSize: const Size(390, 844),
          initialProgressMs: 12000,
          action: 'scrub_nav_replied',
        );
        expect(repliedNav.atRest, [12000]);
        expect(repliedNav.afterExit, [12000]);

        // Landscape center +15s rejected at 750ms -> keeps [750] at rest and after exit.
        final centerReject = await runAvCase(
          viewSize: const Size(844, 390),
          initialProgressMs: 750,
          action: 'center_reject',
        );
        expect(centerReject.atRest, [750]);
        expect(centerReject.afterExit, [750]);

        // Landscape center +15s accepted at 12000ms -> saves [27000] at rest and after exit.
        final centerAccept = await runAvCase(
          viewSize: const Size(844, 390),
          initialProgressMs: 12000,
          action: 'center_accept',
        );
        expect(centerAccept.atRest, [27000]);
        expect(centerAccept.afterExit, [27000]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R6 P2-5: Early UC and Baidu favorite from before owner migration stays playable after same-owner cookie rotation while genuine account switch still rejects',
      () async {
        for (final provider in [
          PersonalCloudProvider.uc,
          PersonalCloudProvider.baidu,
        ]) {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          var sendOwner = false;
          var ownerId = provider == PersonalCloudProvider.uc ? 'uid_A' : '777';
          var sessionToken = 'cookie_initial';

          final httpClient = MockClient((req) async {
            if (provider == PersonalCloudProvider.uc) {
              if (req.url.path.contains('/file/sort')) {
                return http.Response(
                  jsonEncode(<String, dynamic>{
                    'code': 0,
                    'status': 200,
                    if (sendOwner) 'uid': ownerId,
                    'data': {
                      'list': [
                        {
                          'fid': 'fid_1',
                          'file_name': 'movie.mp4',
                          'file_type': 1,
                          'category': 1,
                          'size': 1024,
                        },
                      ],
                    },
                    'metadata': {'_total': 1},
                  }),
                  200,
                );
              }
              if (req.url.path.contains('/file/download')) {
                return http.Response(
                  jsonEncode({
                    'code': 0,
                    'status': 200,
                    'data': [
                      {
                        'fid': 'fid_1',
                        'download_url': 'https://cdn.uc.example/movie.mp4',
                      },
                    ],
                  }),
                  200,
                );
              }
              return http.Response(
                jsonEncode({'code': 0, 'status': 200, 'data': {}}),
                200,
              );
            }
            // Baidu
            if (req.url.path.contains('/api/list')) {
              return http.Response(
                jsonEncode(<String, dynamic>{
                  'errno': 0,
                  if (sendOwner) 'uk': ownerId,
                  'list': [
                    {
                      'fs_id': 1001,
                      'path': '/movies/movie.mp4',
                      'server_filename': 'movie.mp4',
                      'isdir': 0,
                      'category': 1,
                      'size': 1024,
                    },
                  ],
                }),
                200,
              );
            }
            if (req.url.path.contains('/api/filemetas')) {
              return http.Response(
                jsonEncode({
                  'errno': 0,
                  'info': [
                    {'dlink': 'https://d.pcs.baidu.com/file/movie.mp4'},
                  ],
                }),
                200,
              );
            }
            return http.Response(jsonEncode({'errno': 0}), 200);
          });

          final cloudClient = PersonalCloudDriveClient(
            credentialReader: (_) async => provider == PersonalCloudProvider.uc
                ? '__pus=$sessionToken'
                : 'BDUSS=$sessionToken',
            httpClient: httpClient,
          );
          addTearDown(cloudClient.close);

          CmsSite siteFor(SubscriptionEntry entry) {
            final parsed = jsonDecode(entry.rawContent) as Map<String, dynamic>;
            final rawSite = (parsed['sites'] as List).first as Map<String, dynamic>;
            return CmsSite(
              key: '${rawSite['key']}',
              name: '${rawSite['name']}',
              type: 1,
              api: '${rawSite['api']}',
            );
          }

          Future<String> tryPlay(PersonalCloudLibrary lib, CmsVideo card) async {
            try {
              final detail = await lib.detail(card);
              final resolved = await lib.resolve(detail.lines.first.episodes.first);
              final lease = resolved.playbackSession['cloudMediaLease'];
              if (lease is CloudMediaLease) {
                await lease.close();
              }
              return 'playable';
            } on PersonalCloudException catch (e) {
              return e.code;
            }
          }

          // 1. Create library before server returns owner, save early favorite.
          final created = await PersonalCloudLibrary.create(
            client: cloudClient,
            provider: provider,
            folderId: provider.rootFolderId,
            folderName: '我的电影',
            group: '个人网盘',
            isPrivate: false,
          );
          final lib = await PersonalCloudLibrary.open(
            siteFor(created.entry),
            client: cloudClient,
          );
          final earlyCard = (await lib.home()).$2.videos.single;

          // 2. Server starts returning verified owner ID.
          sendOwner = true;
          final ownerCard = (await lib.home()).$2.videos.single;
          final verifiedOwner = lib.accountId;

          // 3. Same owner refreshes cookie (new login session) and re-saves.
          sessionToken = 'cookie_rotated_same_owner';
          final resaved = await PersonalCloudLibrary.create(
            client: cloudClient,
            provider: provider,
            folderId: provider.rootFolderId,
            folderName: '我的电影',
            group: '个人网盘',
            isPrivate: false,
          );
          expect(resaved.entry.id, created.entry.id);
          final reopened = await PersonalCloudLibrary.open(
            siteFor(resaved.entry),
            client: cloudClient,
          );
          expect(reopened.accountId, verifiedOwner);
          final freshCard = (await reopened.home()).$2.videos.single;

          // Early favorite (reconstructed from stored id/title), owner card, and fresh card all play.
          expect(await tryPlay(reopened, freshCard), 'playable');
          expect(await tryPlay(reopened, ownerCard), 'playable');
          expect(
            await tryPlay(
              reopened,
              CmsVideo(id: earlyCard.id, title: earlyCard.title),
            ),
            'playable',
          );

          // 4. Negative control A: foreign card from another unverified cookie is rejected.
          final foreignUrl = Uri.parse(earlyCard.id).replace(
            queryParameters: <String, String>{
              ...Uri.parse(earlyCard.id).queryParameters,
              'account': '${provider.key}:v2:ffffffffffffffff',
            },
          ).toString();
          expect(
            await tryPlay(
              reopened,
              CmsVideo(id: foreignUrl, title: earlyCard.title),
            ),
            'account_mismatch',
          );

          // 5. Negative control B: real account switch (different owner/cookie) rejects early favorite.
          ownerId = provider == PersonalCloudProvider.uc ? 'uid_B' : '888';
          sessionToken = 'cookie_account_B';
          expect(
            await tryPlay(
              reopened,
              CmsVideo(id: earlyCard.id, title: earlyCard.title),
            ),
            'account_mismatch',
          );
        }
      },
    );

    testWidgets(
      'R7 P1-1, P2-3, P2-4: Backup rollback preserves concurrent independent WebDAV pref, checks repeatMode write failure, and normalizes legacy single-key HLS backup',
      (tester) async {
        const cfg =
            '{"sites":[{"key":"f","name":"Fixture","type":1,"api":"https://fixture.example/api"}]}';
        const prevEntry = WatchHistoryEntry(
          site: 'f',
          id: 'previous',
          title: 'Previous',
          updated: 1,
        );
        const importedEntry = WatchHistoryEntry(
          site: 'f',
          id: 'imported',
          title: 'Imported',
          updated: 2,
        );

        final prevPlatform = SharedPreferencesStorePlatform.instance;
        addTearDown(() => SharedPreferencesStorePlatform.instance = prevPlatform);

        // 1. Legacy single-key HLS backup updates BOTH hlsAdRemovalEnabled and hlsAdStripEnabled.
        for (final legacyOnly in [false, true]) {
          SharedPreferencesStorePlatform.instance = prevPlatform;
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final disk = InMemoryStorageFileStore();
          final s = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          await s.setHlsAdStripEnabled(true);
          final payload = CmsParser.encodeBackupPayload(
            origin: '',
            rawConfig: cfg,
            settings: <String, dynamic>{
              StorageService.keyHlsAdRemovalEnabled: false,
              if (!legacyOnly) StorageService.keyHlsAdStripEnabled: false,
            },
          );
          await s.importBackupJson(payload);
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          final cold = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          expect(cold.hlsAdRemovalEnabled, isFalse);
          expect(cold.hlsAdStripEnabled, isFalse);
        }

        // 2. repeatMode returning false fails transaction and rolls back history + repeatMode.
        for (final refuseRepeat in [false, true]) {
          final store = _R7GatedPrefsStore();
          SharedPreferencesStorePlatform.instance = store;
          await (await SharedPreferences.getInstance()).reload();
          final disk = InMemoryStorageFileStore();
          final s = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          await s.setRepeatMode('off');
          await s.upsertWatchHistory(
            prevEntry,
            immediate: true,
            triggerSync: false,
          );
          final payload = CmsParser.encodeBackupPayload(
            origin: '',
            rawConfig: cfg,
            settings: <String, dynamic>{
              StorageService.keyRepeatMode: 'one',
              StorageService.keyWatchHistory: [importedEntry.toJson()],
            },
          );
          store.refuseOnceKey = refuseRepeat
              ? 'flutter.${StorageService.keyRepeatMode}'
              : null;
          Object? err;
          try {
            await s.importBackupJson(payload);
          } catch (e) {
            err = e;
          }
          expect(err != null, refuseRepeat);
          expect(s.repeatMode, refuseRepeat ? 'off' : 'one');
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          final cold = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          expect(cold.repeatMode, refuseRepeat ? 'off' : 'one');
          expect(
            cold.getWatchHistory().map((e) => e.id).toList(),
            refuseRepeat ? ['previous'] : ['imported'],
          );
        }

        // 3. Concurrent independent WebDAV history sync preference survives backup rollback.
        for (final rejectFav in [false, true]) {
          final store = _R7GatedPrefsStore();
          SharedPreferencesStorePlatform.instance = store;
          await (await SharedPreferences.getInstance()).reload();
          final disk = InMemoryStorageFileStore();
          final s = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          await s.setWebdavSyncHistory(true);
          final payload = CmsParser.encodeBackupPayload(
            origin: '',
            rawConfig: cfg,
            settings: <String, dynamic>{
              StorageService.keyWatchHistory: [importedEntry.toJson()],
              StorageService.keyFavorites: [
                {'site': 'f', 'id': 'newFav', 'title': 'New'},
              ],
            },
          );
          store.gateKey = 'flutter.${StorageService.keyFavorites}';
          final pendingImport = s.importBackupJson(payload);
          await store.entered.future;
          await s.setWebdavSyncHistory(false);
          expect(s.webdavSyncHistory, isFalse);
          store.proceed.complete(!rejectFav);
          Object? err;
          try {
            await pendingImport;
          } catch (e) {
            err = e;
          }
          expect(err != null, rejectFav);
          expect(s.webdavSyncHistory, isFalse);
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          final cold = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          expect(cold.webdavSyncHistory, isFalse);
        }
      },
    );

    testWidgets(
      'R7 P2-5: Acknowledged first AVPlayer seek is never reverted to older native sample by a failed or pending second seek',
      (tester) async {
        for (final replySecondBeforeExit in [false, true]) {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final commands = <Completer<bool>>[];
          final targets = <int>[];

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': false,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  final c = Completer<bool>();
                  commands.add(c);
                  targets.add((call.arguments as num).toInt());
                  return c.future;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          final navKey = GlobalKey<NavigatorState>();
          const site = CmsSite(
            key: 's_r7_seek',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r7_seek',
            title: 'R7连续跳转确认测试',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );

          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                home: const Scaffold(body: Text('home')),
              ),
            );
            unawaited(
              navKey.currentState!.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 500));
            await tester.pump(const Duration(milliseconds: 200));

            final mid = avCtrl.currentMediaId;
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': mid,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 12000,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': false,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 12000,
            });
            await tester.pump();

            // 1st seek -> ~50000ms acknowledged without a subsequent progress tick.
            final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
            await tester.tap(slider);
            await tester.pump();
            expect(commands.length, 1);
            commands.first.complete(true);
            await tester.pump();
            final firstTarget = targets.first;
            expect(
              storage
                  .getWatchHistory()
                  .singleWhere((e) => e.id == video.id)
                  .position,
              firstTarget,
            );

            // 2nd seek -> ~25000ms (either rejected before exit or pending at exit).
            final rect = tester.getRect(slider);
            await tester.tapAt(Offset(rect.left + rect.width * 0.25, rect.center.dy));
            await tester.pump();
            expect(commands.length, 2);
            if (replySecondBeforeExit) {
              commands.last.complete(false);
              await tester.pump();
              expect(avCtrl.position.inMilliseconds, firstTarget);
            }

            await navKey.currentState!.maybePop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            if (!replySecondBeforeExit) {
              commands.last.complete(false);
              await tester.pump();
            }

            expect(
              storage
                  .getWatchHistory()
                  .singleWhere((e) => e.id == video.id)
                  .position,
              firstTarget,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 200));
          } finally {
            await fakePlayer.dispose();
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
          }
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R7 P2-6: Direct favorite playback via CmsClient after same-owner relogin verifies ownership on demand and rejects real account switch or unverified owner',
      () async {
        for (final provider in [
          PersonalCloudProvider.uc,
          PersonalCloudProvider.baidu,
        ]) {
          for (final scenario in [
            'direct-same-owner',
            'different-owner',
            'unverified-owner',
          ]) {
            SharedPreferences.setMockInitialValues(<String, Object>{});
            var sendOwner = false;
            var ownerId = provider == PersonalCloudProvider.uc ? 'A' : '777';
            var sessionToken = 'initial_cookie';

            MockClient buildMockHttp() => MockClient((req) async {
                  if (provider == PersonalCloudProvider.uc) {
                    if (req.url.path == '/1/clouddrive/file/sort') {
                      return http.Response(
                        jsonEncode(<String, dynamic>{
                          'status': 200,
                          'code': 0,
                          'data': {
                            if (sendOwner) 'uid': ownerId,
                            'list': [
                              {
                                'fid': '123',
                                'file_name': 'Clip.mp4',
                                'dir': false,
                                'file_type': 1,
                                'category': 1,
                                'size': 1300,
                              },
                            ],
                          },
                          'metadata': {'_total': 1},
                        }),
                        200,
                      );
                    }
                    if (req.url.path == '/1/clouddrive/file/download') {
                      return http.Response(
                        jsonEncode({
                          'status': 200,
                          'code': 0,
                          'data': [
                            {
                              'fid': '123',
                              'download_url': 'https://dl.uc.cn/clip.mp4',
                            },
                          ],
                        }),
                        200,
                      );
                    }
                    return http.Response(
                      jsonEncode({'status': 200, 'code': 0, 'data': {}}),
                      200,
                    );
                  }
                  if (req.url.path == '/api/list') {
                    return http.Response(
                      jsonEncode(<String, dynamic>{
                        'errno': 0,
                        if (sendOwner) 'uk': int.parse(ownerId),
                        'has_more': 0,
                        'list': [
                          {
                            'fs_id': 123,
                            'server_filename': 'Clip.mp4',
                            'path': '/Clip.mp4',
                            'isdir': 0,
                            'category': 1,
                            'size': 1300,
                          },
                        ],
                      }),
                      200,
                    );
                  }
                  if (req.url.path == '/api/filemetas') {
                    return http.Response(
                      jsonEncode({
                        'errno': 0,
                        'info': [
                          {
                            'fs_id': 123,
                            'dlink': 'https://d.pcs.baidu.com/file/123',
                          },
                        ],
                      }),
                      200,
                    );
                  }
                  return http.Response(jsonEncode({'errno': 0}), 200);
                });

            final setupClient = PersonalCloudDriveClient(
              credentialReader: (_) async => provider == PersonalCloudProvider.uc
                  ? '__pus=$sessionToken'
                  : 'BDUSS=$sessionToken',
              httpClient: buildMockHttp(),
            );
            addTearDown(setupClient.close);

            final created = await PersonalCloudLibrary.create(
              client: setupClient,
              provider: provider,
              folderId: provider.rootFolderId,
              folderName: '我的电影',
              group: '个人网盘',
              isPrivate: false,
            );
            final rawSite = (jsonDecode(created.entry.rawContent)['sites'] as List)
                .single as Map<String, dynamic>;
            final site = CmsSite(
              key: '${rawSite['key']}',
              name: '${rawSite['name']}',
              type: 1,
              api: '${rawSite['api']}',
            );
            final lib = await PersonalCloudLibrary.open(
              site,
              client: setupClient,
            );
            final earlyCard = (await lib.home()).$2.videos.single;

            // Verify owner once while on original cookie.
            sendOwner = true;
            await lib.home();

            // Simulate relogin with fresh cookie WITHOUT visiting library first.
            sessionToken = 'relogin_new_cookie';
            if (scenario == 'different-owner') {
              ownerId = provider == PersonalCloudProvider.uc ? 'B' : '888';
            } else if (scenario == 'unverified-owner') {
              sendOwner = false;
            }
            final storage = await StorageService.init();
            await storage.setNetdiskCredential(
              provider.key,
              provider == PersonalCloudProvider.uc
                  ? '__pus=$sessionToken'
                  : 'BDUSS=$sessionToken',
            );

            final episode =
                (await lib.detail(CmsVideo(id: earlyCard.id, title: earlyCard.title)))
                    .lines
                    .single
                    .episodes
                    .single;
            final cms = CmsClient(client: buildMockHttp());
            String result;
            try {
              final resolved = await cms.resolveEpisodeForPlayback(site, episode);
              final lease = resolved.playbackSession['cloudMediaLease'];
              if (lease is CloudMediaLease) {
                await lease.close();
              }
              result = resolved.url.isNotEmpty ? 'playable' : 'empty';
            } on PersonalCloudException catch (e) {
              result = e.code;
            }
            expect(
              result,
              scenario == 'direct-same-owner' ? 'playable' : 'account_mismatch',
            );
          }
        }
      },
    );

    test(
      'R8 P2-2: Backup rollback preserves a later user clearSearchHistory even when transaction wrote the same empty list',
      () async {
        const cfg =
            '{"sites":[{"key":"s1","name":"Site1","type":1,"api":"https://example.com/api"}]}';
        for (final refused in [false, true]) {
          for (final incoming in [<String>['backup-query'], <String>[]]) {
            final store = _R8JournalPrefsStore();
            SharedPreferencesStorePlatform.instance = store;
            final disk = InMemoryStorageFileStore();
            final s = await StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );
            await s.addSearchKeyword('previous-query');
            store.gateKey = 'flutter.${StorageService.keyAutoNext}';
            final importFuture = s.importBackupJson(
              CmsParser.encodeBackupPayload(
                origin: '',
                rawConfig: cfg,
                settings: <String, Object?>{
                  StorageService.keySearchHistory: incoming,
                  StorageService.keyAutoNext: true,
                },
              ),
            );
            await store.entered.future;
            await s.clearSearchHistory();
            expect(s.getSearchHistory(), isEmpty);
            store.proceed.complete(!refused);
            Object? err;
            try {
              await importFuture;
            } catch (e) {
              err = e;
            }
            expect(err != null, refused);
            await (await SharedPreferences.getInstance()).reload();
            final cold = await StorageService.init(
              fileStore: disk,
              secureStore: InMemorySecureCredentialStore(),
            );
            expect(cold.getSearchHistory(), isEmpty);
          }
        }
      },
    );

    test(
      'R8 P2-3: Restoring empty ad domains when cached_ad_hosts removal fails keeps import result, cold config, and player ad domains consistent',
      () async {
        const cleanCfg =
            '{"sites":[{"key":"s1","name":"Site1","type":1,"api":"https://example.com/api"}]}';
        const adCfg =
            '{"sites":[{"key":"s1","name":"Site1","type":1,"api":"https://example.com/api"}],"ads":["old-filter.example"]}';
        for (final refused in [false, true]) {
          final store = _R8JournalPrefsStore();
          SharedPreferencesStorePlatform.instance = store;
          final disk = InMemoryStorageFileStore();
          final s = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          await s.importBackupJson(
            CmsParser.encodeBackupPayload(
              origin: '',
              rawConfig: adCfg,
              settings: const <String, Object?>{},
            ),
          );
          expect(s.cachedAdDomains, ['old-filter.example']);
          if (refused) {
            store.refuseRemoveOnceKey =
                'flutter.${StorageService.keyCachedAdHosts}';
          }
          Object? err;
          try {
            await s.importBackupJson(
              CmsParser.encodeBackupPayload(
                origin: '',
                rawConfig: cleanCfg,
                settings: const <String, Object?>{},
              ),
            );
          } catch (e) {
            err = e;
          }
          await (await SharedPreferences.getInstance()).reload();
          final cold = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          if (refused) {
            expect(err, isA<StateError>());
            expect(cold.loadSavedConfig()?.ads, ['old-filter.example']);
            expect(cold.cachedAdDomains, ['old-filter.example']);
            expect(cold.getSavedAdRules(), ['old-filter.example']);
          } else {
            expect(err, isNull);
            expect(cold.loadSavedConfig()?.ads, isEmpty);
            expect(cold.cachedAdDomains, isEmpty);
            expect(cold.getSavedAdRules(), isEmpty);
          }
        }
      },
    );

    testWidgets(
      'R8 P2-4: Overlapping seeks promote late earlier ack as exit-save baseline without overriding newer ack or valid clock sample',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<int?> runOverlapScenario(String scenario) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final disk = InMemoryStorageFileStore();
          final storage = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final seekCompleters = <Completer<bool>>[];
          final seekTargets = <int>[];

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': true,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  final ms = (call.arguments as num).toInt();
                  seekTargets.add(ms);
                  final c = Completer<bool>();
                  seekCompleters.add(c);
                  return c.future;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          const site = CmsSite(
            key: 's_r8_overlap',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r8_overlap',
            title: 'R8连续Seek回执顺序',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );
          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          final navKey = GlobalKey<NavigatorState>();
          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                initialRoute: '/player',
                home: const Scaffold(body: Text('home')),
                routes: <String, WidgetBuilder>{
                  '/player': (_) => PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  ),
                },
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 250));
            final mid = avCtrl.currentMediaId!;

            // Confirm playback and pause at 12s.
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': mid,
              'durationMs': 100000,
              'positionMs': 10000,
              'playing': true,
              'buffering': false,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'durationMs': 100000,
              'positionMs': 12000,
              'playing': true,
              'buffering': false,
            });
            await tester.pump();
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'durationMs': 100000,
              'positionMs': 12000,
              'playing': false,
              'buffering': false,
            });
            await tester.pump();

            // Tap scrubber at 50% (50000ms), then 25% (25000ms).
            final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
            expect(slider, findsOneWidget);
            await tester.tap(slider);
            await tester.pump();
            final box = tester.getRect(slider);
            await tester.tapAt(
              Offset(box.left + box.width * 0.25, box.center.dy),
            );
            await tester.pump();
            expect(seekCompleters.length, 2);
            expect(seekTargets, [50000, 25000]);

            switch (scenario) {
              case 'first-late-ack-before-second':
                seekCompleters[0].complete(true);
                await tester.pump();
              case 'out-of-order-second-then-first':
                seekCompleters[1].complete(true);
                await tester.pump();
                seekCompleters[0].complete(true);
                await tester.pump();
              case 'newer-clock-blocks-late-first':
                avCtrl.handleNativeEvent(<Object?, Object?>{
                  'type': 'progress',
                  'mediaId': mid,
                  'durationMs': 100000,
                  'positionMs': 25400,
                  'playing': false,
                  'buffering': false,
                });
                await tester.pump();
                seekCompleters[0].complete(true);
                await tester.pump();
              case 'old-reject-keeps-prior':
                seekCompleters[0].complete(false);
                await tester.pump();
            }

            await navKey.currentState!.maybePop();
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 50));

            for (final c in seekCompleters) {
              if (!c.isCompleted) c.complete(false);
            }
            await tester.pump();

            final history = storage.getWatchHistory();
            expect(history, hasLength(1));
            return history.single.position;
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 650));
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
            fakePlayer.dispose();
          }
        }

        // First tap ~50s, second tap ~25s (Slider padding gives exact target).
        final lateFirst = await runOverlapScenario('first-late-ack-before-second');
        final outOfOrder =
            await runOverlapScenario('out-of-order-second-then-first');
        final clockWins =
            await runOverlapScenario('newer-clock-blocks-late-first');
        final oldReject = await runOverlapScenario('old-reject-keeps-prior');

        expect(lateFirst, 50000);
        expect(outOfOrder, 25000);
        expect(clockWins, 25400);
        expect(oldReject, 12000);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R8 P2-5: HTTP 503 during on-demand netdisk owner check stops playback with requiresReauth=false and allows retry, while preserving 401 and real owner switch',
      () async {
        for (final provider in [
          PersonalCloudProvider.uc,
          PersonalCloudProvider.baidu,
        ]) {
          for (final scenario in [
            'busy-once',
            'expired-401',
            'real-switch',
          ]) {
            SharedPreferences.setMockInitialValues(<String, Object>{});
            const oldOwner = '9001';
            const otherOwner = '9002';
            var activeToken = 'tok_initial';
            var verifyChecks = 0;
            var mediaRequests = 0;

            http.Client buildMockHttp() => MockClient((req) async {
                  final path = req.url.path;
                  final cookie = req.headers['cookie'] ?? '';
                  final refreshed = cookie.contains('tok_refreshed');
                  if (provider == PersonalCloudProvider.uc) {
                    if (path == '/1/clouddrive/file/sort') {
                      if (refreshed) {
                        verifyChecks++;
                        if (scenario == 'busy-once' && verifyChecks == 1) {
                          return http.Response('Service Unavailable', 503);
                        }
                        if (scenario == 'expired-401') {
                          return http.Response('Unauthorized', 401);
                        }
                      }
                      final uid =
                          (refreshed && scenario == 'real-switch')
                              ? otherOwner
                              : oldOwner;
                      return http.Response(
                        jsonEncode(<String, Object?>{
                          'status': 200,
                          'code': 0,
                          'data': <String, Object?>{
                            'uid': uid,
                            'list': <Object?>[
                              <String, Object?>{
                                'fid': '123',
                                'file_name': 'Clip.mp4',
                                'dir': false,
                                'file_type': 1,
                                'category': 1,
                                'size': 1300,
                              },
                            ],
                          },
                          'metadata': <String, Object?>{'_total': 1},
                        }),
                        200,
                      );
                    }
                    if (path == '/1/clouddrive/file/download') {
                      mediaRequests++;
                      return http.Response(
                        jsonEncode(<String, Object?>{
                          'status': 200,
                          'code': 0,
                          'data': <Object?>[
                            <String, Object?>{
                              'fid': '123',
                              'download_url': 'https://dl.uc.cn/clip.mp4',
                            },
                          ],
                        }),
                        200,
                      );
                    }
                    return http.Response(
                      jsonEncode(<String, Object?>{
                        'status': 200,
                        'code': 0,
                        'data': const <String, Object?>{},
                      }),
                      200,
                    );
                  }
                  if (path == '/api/list') {
                    if (refreshed) {
                      verifyChecks++;
                      if (scenario == 'busy-once' && verifyChecks == 1) {
                        return http.Response('Service Unavailable', 503);
                      }
                      if (scenario == 'expired-401') {
                        return http.Response('Unauthorized', 401);
                      }
                    }
                    final uk = (refreshed && scenario == 'real-switch')
                        ? int.parse(otherOwner)
                        : int.parse(oldOwner);
                    return http.Response(
                      jsonEncode(<String, Object?>{
                        'errno': 0,
                        'uk': uk,
                        'has_more': 0,
                        'list': <Object?>[
                          <String, Object?>{
                            'fs_id': 123,
                            'server_filename': 'Clip.mp4',
                            'path': '/Clip.mp4',
                            'isdir': 0,
                            'category': 1,
                            'size': 1300,
                          },
                        ],
                      }),
                      200,
                    );
                  }
                  if (path == '/api/filemetas') {
                    mediaRequests++;
                    return http.Response(
                      jsonEncode(<String, Object?>{
                        'errno': 0,
                        'info': <Object?>[
                          <String, Object?>{
                            'fs_id': 123,
                            'dlink': 'https://d.pcs.baidu.com/file/123',
                          },
                        ],
                      }),
                      200,
                    );
                  }
                  return http.Response(
                    jsonEncode(const <String, Object?>{'errno': 0}),
                    200,
                  );
                });

            final setupClient = PersonalCloudDriveClient(
              credentialReader: (_) async => provider == PersonalCloudProvider.uc
                  ? '__pus=$activeToken'
                  : 'BDUSS=$activeToken',
              httpClient: buildMockHttp(),
            );
            addTearDown(setupClient.close);

            final created = await PersonalCloudLibrary.create(
              client: setupClient,
              provider: provider,
              folderId: provider.rootFolderId,
              folderName: 'R8 ${provider.key} $scenario',
              group: '个人网盘',
              isPrivate: false,
            );
            final rawSite = (jsonDecode(created.entry.rawContent)['sites'] as List)
                .single as Map<String, dynamic>;
            final site = CmsSite(
              key: '${rawSite['key']}',
              name: '${rawSite['name']}',
              type: 1,
              api: '${rawSite['api']}',
            );
            final lib = await PersonalCloudLibrary.open(
              site,
              client: setupClient,
            );
            final card = (await lib.home()).$2.videos.single;

            // Refresh credential without browsing first.
            activeToken = 'tok_refreshed';
            final storage = await StorageService.init();
            await storage.setNetdiskCredential(
              provider.key,
              provider == PersonalCloudProvider.uc
                  ? '__pus=$activeToken'
                  : 'BDUSS=$activeToken',
            );
            final episode =
                (await lib.detail(CmsVideo(id: card.id, title: card.title)))
                    .lines
                    .single
                    .episodes
                    .single;

            Future<({String result, bool reauth})> attemptPlay() async {
              final cms = CmsClient(client: buildMockHttp());
              try {
                final resolved =
                    await cms.resolveEpisodeForPlayback(site, episode);
                final lease = resolved.playbackSession['cloudMediaLease'];
                if (lease is CloudMediaLease) {
                  await lease.close();
                }
                return (
                  result: resolved.url.isNotEmpty ? 'playable' : 'empty',
                  reauth: false,
                );
              } on PersonalCloudException catch (e) {
                return (result: e.code, reauth: e.requiresReauth);
              }
            }

            final first = await attemptPlay();
            expect(mediaRequests, 0, reason: '$provider/$scenario first attempt must not fetch media');
            if (scenario == 'busy-once') {
              expect(first.result, 'http_503');
              expect(first.reauth, isFalse);
              final second = await attemptPlay();
              expect(second.result, 'playable');
              expect(second.reauth, isFalse);
              expect(verifyChecks, 2);
            } else if (scenario == 'expired-401') {
              expect(first.result, 'auth_expired');
              expect(first.reauth, isTrue);
            } else {
              expect(first.result, 'account_mismatch');
              expect(first.reauth, isTrue);
            }
          }
        }
      },
    );

    testWidgets(
      'R9 P2-2: Settled confirmed seek syncs UI, +15s relative jump, and exit save across out-of-order rejection and pre-landing samples',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<({int shown, List<int> targets, int saved})> runCase(
          String mode,
        ) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final completers = <Completer<bool>>[];
          final targets = <int>[];

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': true,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  final c = Completer<bool>();
                  completers.add(c);
                  targets.add((call.arguments as num).toInt());
                  return c.future;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          const site = CmsSite(
            key: 's_r9_seek',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r9_seek',
            title: 'R9连续Seek与快进一致性',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );
          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          final navKey = GlobalKey<NavigatorState>();
          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                initialRoute: '/player',
                home: const Scaffold(body: Text('home')),
                routes: <String, WidgetBuilder>{
                  '/player': (_) => PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  ),
                },
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 250));
            final mid = avCtrl.currentMediaId!;

            Future<void> emitClock(int ms, {bool playing = false}) async {
              avCtrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': playing,
                'buffering': false,
                'durationMs': 100000,
                'positionMs': ms,
              });
              await tester.pump();
            }

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            await emitClock(12000, playing: true);
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': false,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 12000,
            });
            await tester.pump();

            final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
            expect(slider, findsOneWidget);
            await tester.tap(slider);
            await tester.pump();
            if (mode.startsWith('preLanding')) {
              await emitClock(12000);
            }
            final rect = tester.getRect(slider);
            await tester.tapAt(
              Offset(rect.left + rect.width * 0.25, rect.center.dy),
            );
            await tester.pump();
            expect(targets, [50000, 25000]);

            if (mode == 'rejectedSecondLateFirstForward') {
              completers[1].complete(false);
              await tester.pump();
              completers[0].complete(true);
              await tester.pump();
            } else if (mode == 'cleanLateFirstForward') {
              completers[0].complete(true);
              await tester.pump();
              completers[1].complete(false);
              await tester.pump();
            } else if (mode == 'preLandingSampleBeforeSecond') {
              completers[0].complete(true);
              await tester.pump();
              completers[1].complete(false);
              await tester.pump();
            } else if (mode == 'preLandingSampleRejectBoth') {
              completers[0].complete(false);
              await tester.pump();
              completers[1].complete(false);
              await tester.pump();
            } else if (mode == 'preLandingLatestAccepted') {
              completers[0].complete(true);
              await tester.pump();
              completers[1].complete(true);
              await tester.pump();
            } else if (mode == 'landingAfterSecond') {
              await emitClock(25400);
              completers[0].complete(true);
              await tester.pump();
              completers[1].complete(false);
              await tester.pump();
            }

            final shown = avCtrl.position.inMilliseconds;
            if (mode.endsWith('Forward')) {
              final fwd = find.byKey(const Key('player-center-forward'));
              expect(fwd, findsOneWidget);
              await tester.tap(fwd);
              await tester.pump();
              expect(completers.length, 3);
              completers[2].complete(true);
              await tester.pump();
            }

            expect(await navKey.currentState!.maybePop(), isTrue);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();

            final saved = storage.getWatchHistory().single.position;
            return (shown: shown, targets: targets, saved: saved);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 650));
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
            fakePlayer.dispose();
          }
        }

        final r1 = await runCase('rejectedSecondLateFirstForward');
        expect(r1.shown, 50000);
        expect(r1.targets, [50000, 25000, 65000]);
        expect(r1.saved, 65000);

        final r2 = await runCase('cleanLateFirstForward');
        expect(r2.shown, 50000);
        expect(r2.targets, [50000, 25000, 65000]);
        expect(r2.saved, 65000);

        final r3 = await runCase('preLandingSampleBeforeSecond');
        expect(r3.shown, 50000);
        expect(r3.saved, 50000);

        final r4 = await runCase('preLandingSampleRejectBoth');
        expect(r4.shown, 12000);
        expect(r4.saved, 12000);

        final r5 = await runCase('preLandingLatestAccepted');
        expect(r5.shown, 25000);
        expect(r5.saved, 25000);

        final r6 = await runCase('landingAfterSecond');
        expect(r6.shown, 25400);
        expect(r6.saved, 25400);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R9 P2-3: Partial failure during WindowsAppearancePreferences backup restore rolls back all appearance keys and keeps re-exported backup clean',
      () async {
        const cfg =
            '{"sites":[{"key":"s1","name":"Site1","type":1,"api":"https://example.com/api"}]}';
        for (final refusal in ['none', 'preset', 'mode', 'image']) {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final store = _R9AppearancePrefsStore();
          SharedPreferencesStorePlatform.instance = store;
          final disk = InMemoryStorageFileStore();
          final s = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('windows_v4_preset', 'slate');
          await prefs.setString('windows_v4_mode', 'light');
          await prefs.setString('windows_v4_image', 'local-photo');
          if (refusal != 'none') {
            store.refuseOnceKey = 'flutter.windows_v4_$refusal';
          }
          final backup = CmsParser.encodeBackupPayload(
            origin: '',
            rawConfig: cfg,
            settings: <String, Object?>{
              WindowsAppearancePreferences.key: <String, Object?>{
                'version': 1,
                'preset': 'paper',
                'mode': 'dark',
              },
            },
          );
          Object? err;
          try {
            await s.importBackupJson(backup);
          } catch (e) {
            err = e;
          }
          await prefs.reload();
          final reopened = await StorageService.init(
            fileStore: disk,
            secureStore: InMemorySecureCredentialStore(),
          );
          final actualDisk = [
            prefs.getString('windows_v4_preset'),
            prefs.getString('windows_v4_mode'),
            prefs.getString('windows_v4_image'),
          ];
          final exported = CmsParser.decodeBackupPayload(
            reopened.exportBackupJson(),
          ).settings[WindowsAppearancePreferences.key] as Map;
          if (refusal == 'none') {
            expect(err, isNull);
            expect(actualDisk, ['paper', 'dark', '']);
            expect([exported['preset'], exported['mode']], ['paper', 'dark']);
          } else {
            expect(err, isA<StateError>());
            expect(actualDisk, ['slate', 'light', 'local-photo']);
            expect([exported['preset'], exported['mode']], ['slate', 'light']);
          }
        }
      },
    );

    testWidgets(
      'R10 P2-a: Playing forward/backward overlapping seeks ignore pre-seek ticks while preserving genuine post-landing clock samples in scrubber and exit history',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        Future<({int shown, int thumb, int saved})> runPlayingCase(
          String mode,
        ) async {
          SharedPreferences.setMockInitialValues(<String, Object>{});
          final storage = await StorageService.init(
            fileStore: InMemoryStorageFileStore(),
            secureStore: InMemorySecureCredentialStore(),
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final completers = <Completer<bool>>[];
          final targets = <int>[];

          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              switch (call.method) {
                case 'getTelemetry':
                  return <String, Object?>{
                    'thermalState': 'nominal',
                    'physicalMemoryBytes': 6 * 1024 * 1024 * 1024,
                    'isPipSupported': true,
                    'isPipPossible': true,
                    'isPipActive': false,
                    'systemVolume': 0.5,
                    'isAirPlayActive': false,
                  };
                case 'open':
                  return true;
                case 'seek':
                  final c = Completer<bool>();
                  completers.add(c);
                  targets.add((call.arguments as num).toInt());
                  return c.future;
                default:
                  return null;
              }
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          const site = CmsSite(
            key: 's_r10_play_seek',
            name: '测试源',
            type: 1,
            api: 'https://fixture.example/api',
          );
          const video = CmsVideo(
            id: 'vid_r10_play_seek',
            title: 'R10播放中连续Seek',
            lines: [
              CmsLine(
                id: 'line_a',
                name: '线路A',
                episodes: [
                  CmsEpisode(name: '第1集', url: 'https://cdn.example/ep1.m3u8'),
                ],
              ),
            ],
          );
          final avCtrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          final fakePlayer = _SilentFakePlayer();
          final navKey = GlobalKey<NavigatorState>();
          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navKey,
                initialRoute: '/player',
                home: const Scaffold(body: Text('home')),
                routes: <String, WidgetBuilder>{
                  '/player': (_) => PlayerScreen(
                    site: site,
                    video: video,
                    initialLineIndex: 0,
                    initialEpisodeIndex: 0,
                    storage: storage,
                    debugPlayer: fakePlayer,
                    debugIosAvPlayerController: avCtrl,
                    debugVideoSurface: const ColoredBox(color: Colors.black),
                  ),
                },
              ),
            );
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 250));
            final mid = avCtrl.currentMediaId!;
            final start = mode.startsWith('forward') ? 12000 : 80000;
            final update = start + (mode == 'backwardDuplicate' ? 0 : 250);

            Future<void> emitPlayingClock(int ms) async {
              avCtrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'buffering': false,
                'durationMs': 100000,
                'positionMs': ms,
              });
              await tester.pump();
            }

            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'ready',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': 0,
            });
            await tester.pump();
            await emitPlayingClock(start);
            avCtrl.handleNativeEvent(<Object?, Object?>{
              'type': 'playbackState',
              'mediaId': mid,
              'playing': true,
              'buffering': false,
              'durationMs': 100000,
              'positionMs': start,
            });
            await tester.pump();

            final slider = find.byKey(const Key('ios-fluid-scrubber-hit-area'));
            expect(slider, findsOneWidget);
            await tester.tap(slider);
            await tester.pump();
            if (mode.endsWith('Before') || mode == 'backwardDuplicate') {
              await emitPlayingClock(update);
            }
            final rect = tester.getRect(slider);
            await tester.tapAt(
              Offset(rect.left + rect.width * 0.25, rect.center.dy),
            );
            await tester.pump();
            expect(targets, [50000, 25000]);

            if (mode.endsWith('After') ||
                mode == 'latestSuccess' ||
                mode == 'bothRejected') {
              await emitPlayingClock(update);
            }
            if (mode == 'postLanding') {
              await emitPlayingClock(25400);
            }
            completers[0].complete(mode != 'bothRejected');
            await tester.pump();
            completers[1].complete(mode == 'latestSuccess');
            await tester.pump();

            final shown = avCtrl.position.inMilliseconds;
            final scrubber = tester.widget<IosFluidScrubberCapsule>(
              find.ancestor(
                of: slider,
                matching: find.byType(IosFluidScrubberCapsule),
              ),
            );
            final thumb = scrubber.position.inMilliseconds;

            expect(await navKey.currentState!.maybePop(), isTrue);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();

            final saved = storage.getWatchHistory().single.position;
            return (shown: shown, thumb: thumb, saved: saved);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 650));
            messenger.setMockMethodCallHandler(
              IosAvPlayerController.defaultChannel,
              null,
            );
            messenger.setMockMethodCallHandler(
              MethodChannel(IosAvPlayerController.defaultEventChannel.name),
              null,
            );
            fakePlayer.dispose();
          }
        }

        const expectedByMode = <String, int>{
          'forwardBefore': 50000,
          'forwardAfter': 50000,
          'backwardBefore': 50000,
          'backwardAfter': 50000,
          'backwardDuplicate': 50000,
          'latestSuccess': 25000,
          'bothRejected': 80250,
          'postLanding': 25400,
        };
        for (final entry in expectedByMode.entries) {
          final res = await runPlayingCase(entry.key);
          expect(res.shown, entry.value, reason: 'shown mismatch for ${entry.key}');
          expect(res.thumb, entry.value, reason: 'scrubber mismatch for ${entry.key}');
          expect(res.saved, entry.value, reason: 'saved mismatch for ${entry.key}');
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    test(
      'R10 P2-b: Native monotonic eventSeq orders seek landings and clock samples deterministically even for identical positions or out-of-order delivery',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final seekCompleters = <Completer<Object?>>[];
        messenger.setMockMethodCallHandler(
          IosAvPlayerController.defaultChannel,
          (call) async {
            if (call.method == 'open') return true;
            if (call.method == 'seek') {
              final c = Completer<Object?>();
              seekCompleters.add(c);
              return c.future;
            }
            return null;
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel(IosAvPlayerController.defaultEventChannel.name),
          (call) async => null,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        final ctrl = IosAvPlayerController(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        );
        addTearDown(ctrl.dispose);

        await ctrl.open(
          'https://cdn.example/ep1.m3u8',
          startPosition: Duration.zero,
        );
        final mid = ctrl.currentMediaId!;
        ctrl.handleNativeEvent(<Object?, Object?>{
          'type': 'progress',
          'mediaId': mid,
          'playing': true,
          'durationMs': 100000,
          'positionMs': 80000,
          'eventSeq': 10,
        });
        expect(ctrl.confirmedPosition, const Duration(milliseconds: 80000));

        // Dispatch tiny 100ms backward seek (gen 1 -> 79900ms) and second seek (gen 2 -> 25000ms).
        final f1 = ctrl.seek(const Duration(milliseconds: 79900));
        final f2 = ctrl.seek(const Duration(milliseconds: 25000));
        // Native emitted a pre-seek clock tick at eventSeq=11 (80250ms),
        // then finished seek 1 at eventSeq=12 (79900ms), and cancelled seek 2.
        ctrl.handleNativeEvent(<Object?, Object?>{
          'type': 'progress',
          'mediaId': mid,
          'playing': true,
          'durationMs': 100000,
          'positionMs': 80250,
          'eventSeq': 11,
        });
        seekCompleters[0].complete(<String, Object?>{
          'finished': true,
          'mediaId': mid,
          'eventSeq': 12,
          'positionMs': 79900,
        });
        seekCompleters[1].complete(false);
        expect(await f1, isTrue);
        expect(await f2, isFalse);
        expect(ctrl.confirmedPosition, const Duration(milliseconds: 79900));
        expect(ctrl.position, const Duration(milliseconds: 79900));

        // An out-of-order older clock event (eventSeq=10) arriving late must not
        // regress confirmedPosition or displayed position.
        ctrl.handleNativeEvent(<Object?, Object?>{
          'type': 'progress',
          'mediaId': mid,
          'playing': true,
          'durationMs': 100000,
          'positionMs': 80000,
          'eventSeq': 10,
        });
        expect(ctrl.confirmedPosition, const Duration(milliseconds: 79900));
        expect(ctrl.position, const Duration(milliseconds: 79900));

        // A genuinely newer native clock sample (eventSeq=13) immediately takes precedence.
        ctrl.handleNativeEvent(<Object?, Object?>{
          'type': 'progress',
          'mediaId': mid,
          'playing': true,
          'durationMs': 100000,
          'positionMs': 80200,
          'eventSeq': 13,
        });
        expect(ctrl.confirmedPosition, const Duration(milliseconds: 80200));
        expect(ctrl.position, const Duration(milliseconds: 80200));
      },
    );

    test(
      'R11 P2-2: Pre-seek native clock ticks during a pending seek keep the pending seek target for relative +15s jumps while preserving real clock rollback on failure',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<({int beforeForward, List<int> targets, int confirmedMs})> runPhase(
          String phase,
        ) async {
          final targets = <int>[];
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                targets.add((call.arguments as num).toInt());
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r11_pending.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;
            ctrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 12000,
              'eventSeq': 3,
            });

            if (phase == 'oldTickBefore') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 12250,
                'eventSeq': 4,
              });
            }

            final f1 = ctrl.seek(const Duration(milliseconds: 50000));
            if (phase == 'oldTickPending' || phase == 'failedFirst') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 12250,
                'eventSeq': 4,
              });
            }
            if (phase == 'failedFirst') {
              completers[0].complete(<String, Object?>{'finished': false});
              expect(await f1, isFalse);
            } else if (phase == 'oldTickAfterAck' ||
                phase == 'landedTickAfterAck') {
              completers[0].complete(<String, Object?>{
                'finished': true,
                'mediaId': mid,
                'eventSeq': 5,
                'positionMs': 50000,
              });
              expect(await f1, isTrue);
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': phase == 'landedTickAfterAck' ? 50250 : 12250,
                'eventSeq': phase == 'landedTickAfterAck' ? 6 : 4,
              });
            }

            final beforeForward = ctrl.position.inMilliseconds;
            final f2 = ctrl.seek(
              Duration(milliseconds: beforeForward + 15000),
            );
            if (!completers[0].isCompleted) {
              completers[0].complete(<String, Object?>{
                'finished': true,
                'mediaId': mid,
                'eventSeq': 5,
                'positionMs': 50000,
              });
              expect(await f1, isTrue);
            }
            final secondTarget = targets.last;
            completers[1].complete(<String, Object?>{
              'finished': true,
              'mediaId': mid,
              'eventSeq': 7,
              'positionMs': secondTarget,
            });
            expect(await f2, isTrue);

            return (
              beforeForward: beforeForward,
              targets: targets,
              confirmedMs: ctrl.confirmedPosition!.inMilliseconds,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected = <String, ({int before, int target2})>{
          'noTick': (before: 50000, target2: 65000),
          'oldTickBefore': (before: 50000, target2: 65000),
          'oldTickPending': (before: 50000, target2: 65000),
          'oldTickAfterAck': (before: 50000, target2: 65000),
          'landedTickAfterAck': (before: 50250, target2: 65250),
          'failedFirst': (before: 12250, target2: 27250),
        };
        for (final entry in expected.entries) {
          final res = await runPhase(entry.key);
          expect(res.beforeForward, entry.value.before, reason: entry.key);
          expect(res.targets, [50000, entry.value.target2], reason: entry.key);
          expect(res.confirmedMs, entry.value.target2, reason: entry.key);
        }
      },
    );

    test(
      'R11 P2-3: Same-media stale completion during or after a scrub-back seek is suppressed while genuine and rejected-seek completions still complete',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<({bool completed, int posMs})> runCompletionMode(
          String mode,
        ) async {
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r11_end.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;

            if (mode == 'priorSeekThenRejectedLegacyEnd') {
              // Earlier seek in the same episode succeeded on legacy bool bridge.
              final f0 = ctrl.seek(const Duration(milliseconds: 20000));
              completers.removeAt(0).complete(true);
              expect(await f0, isTrue);
            }

            ctrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 99750,
              if (mode != 'priorSeekThenRejectedLegacyEnd') 'eventSeq': 3,
            });

            final f = ctrl.seek(const Duration(milliseconds: 50000));
            if (mode == 'staleCompletionDuringSeek' ||
                mode == 'completionBeforeRejectedSeek' ||
                mode == 'priorSeekThenRejectedLegacyEnd') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'completed',
                'mediaId': mid,
                'positionMs': 100000,
                'durationMs': 100000,
                if (mode != 'priorSeekThenRejectedLegacyEnd') 'eventSeq': 4,
              });
              // Must remain deferred until the in-flight seek settles.
              expect(ctrl.completed, isFalse, reason: '$mode premature complete');
            }

            if (mode == 'completionBeforeRejectedSeek') {
              completers[0].complete(<String, Object?>{'finished': false});
              expect(await f, isFalse);
            } else if (mode == 'priorSeekThenRejectedLegacyEnd') {
              completers[0].complete(false);
              expect(await f, isFalse);
            } else {
              completers[0].complete(<String, Object?>{
                'finished': true,
                'mediaId': mid,
                'eventSeq': 5,
                'positionMs': 50000,
              });
              expect(await f, isTrue);
            }

            if (mode == 'staleCompletionAfterAck') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'completed',
                'mediaId': mid,
                'positionMs': 100000,
                'durationMs': 100000,
                'eventSeq': 4,
              });
            } else if (mode == 'freshCompletionAfterAck') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'completed',
                'mediaId': mid,
                'positionMs': 100000,
                'durationMs': 100000,
                'eventSeq': 6,
              });
            } else if (mode == 'wrongMediaCompletion') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'completed',
                'mediaId': mid - 1,
                'positionMs': 100000,
                'durationMs': 100000,
                'eventSeq': 6,
              });
            }

            return (
              completed: ctrl.completed,
              posMs: (ctrl.confirmedPosition ?? ctrl.position).inMilliseconds,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected = <String, ({bool completed, int posMs})>{
          'noCompletion': (completed: false, posMs: 50000),
          'staleCompletionAfterAck': (completed: false, posMs: 50000),
          'freshCompletionAfterAck': (completed: true, posMs: 100000),
          'wrongMediaCompletion': (completed: false, posMs: 50000),
          'staleCompletionDuringSeek': (completed: false, posMs: 50000),
          'completionBeforeRejectedSeek': (completed: true, posMs: 100000),
          'priorSeekThenRejectedLegacyEnd': (completed: true, posMs: 100000),
        };
        for (final entry in expected.entries) {
          final res = await runCompletionMode(entry.key);
          expect(res.completed, entry.value.completed, reason: entry.key);
          expect(res.posMs, entry.value.posMs, reason: entry.key);
        }
      },
    );

    test(
      'R11 P2-4: Legacy bool-only bridge never attributes a clock sample that arrived before a second seek was dispatched to that later seek',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<({int posMs, int confirmedMs})> runLegacyCase(String mode) async {
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r11_legacy.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;
            ctrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 12000,
              if (mode == 'near-second-typed') 'eventSeq': 3,
            });

            final f1 = ctrl.seek(const Duration(milliseconds: 50000));
            if (mode != 'near-second-no-tick') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 12250,
                if (mode == 'near-second-typed') 'eventSeq': 4,
              });
            }
            final secondTarget = mode == 'far-second' ? 25000 : 12400;
            final f2 = ctrl.seek(Duration(milliseconds: secondTarget));

            if (mode == 'near-second-reversed') {
              completers[1].complete(false);
              expect(await f2, isFalse);
              completers[0].complete(true);
              expect(await f1, isTrue);
            } else if (mode == 'near-second-typed') {
              completers[0].complete(<String, Object?>{
                'finished': true,
                'mediaId': mid,
                'eventSeq': 5,
                'positionMs': 50000,
              });
              completers[1].complete(<String, Object?>{'finished': false});
              expect(await f1, isTrue);
              expect(await f2, isFalse);
            } else if (mode == 'near-second-wins') {
              completers[0].complete(true);
              completers[1].complete(true);
              expect(await f1, isTrue);
              expect(await f2, isTrue);
            } else if (mode == 'near-second-both-fail') {
              completers[0].complete(false);
              completers[1].complete(false);
              expect(await f1, isFalse);
              expect(await f2, isFalse);
            } else {
              completers[0].complete(true);
              completers[1].complete(false);
              expect(await f1, isTrue);
              expect(await f2, isFalse);
            }

            return (
              posMs: ctrl.position.inMilliseconds,
              confirmedMs: ctrl.confirmedPosition!.inMilliseconds,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected = <String, int>{
          'far-second': 50000,
          'near-second': 50000,
          'near-second-typed': 50000,
          'near-second-wins': 12400,
          'near-second-both-fail': 12250,
          'near-second-no-tick': 50000,
          'near-second-reversed': 50000,
        };
        for (final entry in expected.entries) {
          final res = await runLegacyCase(entry.key);
          expect(res.posMs, entry.value, reason: '${entry.key} position');
          expect(res.confirmedMs, entry.value, reason: '${entry.key} confirmed');
        }
      },
    );

    test(
      'R12 P2-1: Once the latest user seek settles, a lingering older superseded seek does not freeze displayed position or relative +15s jumps',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<
          ({
            int confirmedMs,
            int shownBeforeForwardMs,
            List<int> targets,
            int finalConfirmedMs,
          })
        >
        runSupersededMode(String mode) async {
          final targets = <int>[];
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                targets.add((call.arguments as num).toInt());
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r12_superseded.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;
            ctrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 12000,
              'eventSeq': 3,
            });

            Future<bool>? fOld;
            if (mode != 'single') {
              fOld = ctrl.seek(const Duration(milliseconds: 50000));
            }
            final fLatest = ctrl.seek(const Duration(milliseconds: 25000));
            if (mode == 'oldFailedEarly' || mode == 'bothFailed') {
              completers.first.complete(false);
              expect(await fOld!, isFalse);
            }
            completers.last.complete(
              mode == 'bothFailed'
                  ? false
                  : <String, Object?>{
                      'finished': true,
                      'mediaId': mid,
                      'eventSeq': 5,
                      'positionMs': 25000,
                    },
            );
            expect(await fLatest, mode != 'bothFailed');

            final tickCount = mode == 'oldStillPendingSmallTick' ? 1 : 8;
            final baseMs = mode == 'bothFailed' ? 12000 : 25000;
            for (var i = 1; i <= tickCount; i++) {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': baseMs + 250 * i,
                'eventSeq': 5 + i,
              });
            }

            final confirmedMs = ctrl.confirmedPosition!.inMilliseconds;
            final shownBefore = ctrl.position.inMilliseconds;
            if (mode != 'oldPendingExit') {
              final fForward = ctrl.seek(
                Duration(milliseconds: shownBefore + 15000),
              );
              completers.last.complete(<String, Object?>{
                'finished': true,
                'mediaId': mid,
                'eventSeq': 20,
                'positionMs': targets.last,
              });
              expect(await fForward, isTrue);
            }
            if (fOld != null && !completers.first.isCompleted) {
              completers.first.complete(false);
              expect(await fOld, isFalse);
            }

            return (
              confirmedMs: confirmedMs,
              shownBeforeForwardMs: shownBefore,
              targets: targets,
              finalConfirmedMs: ctrl.confirmedPosition!.inMilliseconds,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected =
            <String, ({int clock, int finalPos, List<int> targets})>{
              'single': (clock: 27000, finalPos: 42000, targets: [25000, 42000]),
              'oldFailedEarly': (
                clock: 27000,
                finalPos: 42000,
                targets: [50000, 25000, 42000],
              ),
              'oldStillPending': (
                clock: 27000,
                finalPos: 42000,
                targets: [50000, 25000, 42000],
              ),
              'oldPendingExit': (
                clock: 27000,
                finalPos: 27000,
                targets: [50000, 25000],
              ),
              'oldStillPendingSmallTick': (
                clock: 25250,
                finalPos: 40250,
                targets: [50000, 25000, 40250],
              ),
              'bothFailed': (
                clock: 14000,
                finalPos: 29000,
                targets: [50000, 25000, 29000],
              ),
            };
        for (final entry in expected.entries) {
          final res = await runSupersededMode(entry.key);
          expect(res.confirmedMs, entry.value.clock, reason: entry.key);
          expect(
            res.shownBeforeForwardMs,
            entry.value.clock,
            reason: '${entry.key} shown',
          );
          expect(res.targets, entry.value.targets, reason: entry.key);
          expect(
            res.finalConfirmedMs,
            entry.value.finalPos,
            reason: '${entry.key} final',
          );
        }
      },
    );

    test(
      'R12 P2-2 & P2-3: Endpoint seek preserves genuine completion while scrub-back completion watermark suppresses stale completion even when a newer clock arrives before seek ack',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<({bool completed, int confirmedMs, int shownMs})>
        runWatermarkMode(String mode) async {
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r12_watermark.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;
            ctrl.handleNativeEvent(<Object?, Object?>{
              'type': 'progress',
              'mediaId': mid,
              'playing': true,
              'durationMs': 100000,
              'positionMs': 99750,
              'eventSeq': 3,
            });

            final seeksToEnd =
                mode == 'acceptedAtEnd' ||
                mode == 'refusedAtEnd' ||
                mode == 'freshCompletionAtEndpoint';
            final targetMs = seeksToEnd ? 100000 : 50000;
            final f = ctrl.seek(Duration(milliseconds: targetMs));

            void sendCompleted(int seq) {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'completed',
                'mediaId': mid,
                'positionMs': 100000,
                'durationMs': 100000,
                'eventSeq': seq,
              });
            }

            if (mode == 'orderedBackward' ||
                mode == 'laterClockBeforeAck' ||
                mode == 'acceptedAtEnd' ||
                mode == 'refusedAtEnd') {
              sendCompleted(4);
              expect(ctrl.completed, isFalse, reason: '$mode premature end');
            }
            if (mode == 'laterClockBeforeAck' ||
                mode == 'laterClockWithoutEnd' ||
                mode == 'lateCompletedAfterLaterClockAndAck') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 50250,
                'eventSeq': 6,
              });
            }

            completers.single.complete(
              mode == 'refusedAtEnd'
                  ? false
                  : <String, Object?>{
                      'finished': true,
                      'mediaId': mid,
                      'eventSeq': 5,
                      'positionMs': targetMs,
                    },
            );
            expect(await f, mode != 'refusedAtEnd');

            if (mode == 'orderedBackward') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 50250,
                'eventSeq': 6,
              });
            } else if (mode == 'freshCompletionAtEndpoint') {
              sendCompleted(6);
            } else if (mode == 'genuineNewEnd') {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': 'progress',
                'mediaId': mid,
                'playing': true,
                'durationMs': 100000,
                'positionMs': 99750,
                'eventSeq': 6,
              });
              sendCompleted(7);
            } else if (mode == 'completedNearEndBackward' ||
                mode == 'lateCompletedAfterLaterClockAndAck') {
              sendCompleted(4);
            }

            return (
              completed: ctrl.completed,
              confirmedMs: ctrl.confirmedPosition!.inMilliseconds,
              shownMs: ctrl.position.inMilliseconds,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected =
            <String, ({bool completed, int confirmedMs})>{
              'orderedBackward': (completed: false, confirmedMs: 50250),
              'laterClockBeforeAck': (completed: false, confirmedMs: 50250),
              'freshCompletionAtEndpoint': (completed: true, confirmedMs: 100000),
              'laterClockWithoutEnd': (completed: false, confirmedMs: 50250),
              'genuineNewEnd': (completed: true, confirmedMs: 100000),
              'acceptedAtEnd': (completed: true, confirmedMs: 100000),
              'refusedAtEnd': (completed: true, confirmedMs: 100000),
              'completedNearEndBackward': (completed: false, confirmedMs: 50000),
              'lateCompletedAfterLaterClockAndAck': (
                completed: false,
                confirmedMs: 50250,
              ),
            };
        for (final entry in expected.entries) {
          final res = await runWatermarkMode(entry.key);
          expect(res.completed, entry.value.completed, reason: entry.key);
          expect(res.confirmedMs, entry.value.confirmedMs, reason: entry.key);
          expect(res.shownMs, entry.value.confirmedMs, reason: '${entry.key} shown');
        }
      },
    );

    test(
      'R13 P2: Near-end scrub-back strictly before duration suppresses older completed events (including after pause) while exact endpoint seek, fresh completion, and rejected seek still complete',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            null,
          );
        });

        Future<({bool completed, int confirmedMs, bool playing})> runNearEndMode(
          String mode,
        ) async {
          final completers = <Completer<Object?>>[];
          messenger.setMockMethodCallHandler(
            IosAvPlayerController.defaultChannel,
            (call) async {
              if (call.method == 'open') return true;
              if (call.method == 'seek') {
                final c = Completer<Object?>();
                completers.add(c);
                return c.future;
              }
              return null;
            },
          );
          messenger.setMockMethodCallHandler(
            MethodChannel(IosAvPlayerController.defaultEventChannel.name),
            (call) async => null,
          );

          final ctrl = IosAvPlayerController(
            platformOverride: TargetPlatform.iOS,
            isOhosOverride: false,
            isWebOverride: false,
          );
          try {
            await ctrl.open(
              'https://cdn.example/r13_near_end.mp4',
              startPosition: Duration.zero,
            );
            final mid = ctrl.currentMediaId!;
            final duration = mode.startsWith('normal') ? 100000 : 1600;
            final start = duration - 10;
            final desired = mode == 'endpoint'
                ? duration
                : mode == 'away'
                ? 1120
                : mode == 'normalAway'
                ? 99400
                : mode == 'normalNear'
                ? 99600
                : 1280;

            void fire(String type, int seq, int pos, {bool playing = true}) {
              ctrl.handleNativeEvent(<Object?, Object?>{
                'type': type,
                'mediaId': mid,
                'eventSeq': seq,
                'durationMs': duration,
                'positionMs': pos,
                'playing': playing,
                'buffering': false,
              });
            }

            fire('ready', 1, 0);
            fire('playbackState', 2, 0);
            fire('progress', 3, start);

            final f = ctrl.seek(Duration(milliseconds: desired));
            if (mode != 'nearLate' &&
                mode != 'pausedNear' &&
                mode != 'nearFresh') {
              fire('completed', 4, duration, playing: false);
              expect(ctrl.completed, isFalse, reason: '$mode premature end');
            }

            completers.single.complete(
              mode == 'rejected'
                  ? false
                  : <String, Object?>{
                      'finished': true,
                      'mediaId': mid,
                      'eventSeq': 5,
                      'positionMs': desired,
                    },
            );
            expect(await f, mode != 'rejected');

            if (mode == 'nearLate') {
              fire('completed', 4, duration, playing: false);
            } else if (mode == 'pausedNear') {
              await ctrl.pause();
              fire('playbackState', 6, desired, playing: false);
              fire('completed', 4, duration, playing: false);
            } else if (mode == 'nearFresh') {
              fire('completed', 6, duration, playing: false);
            }

            return (
              completed: ctrl.completed,
              confirmedMs: ctrl.confirmedPosition!.inMilliseconds,
              playing: ctrl.playing,
            );
          } finally {
            ctrl.dispose();
          }
        }

        const expected =
            <String, ({bool completed, int confirmedMs})>{
              'nearPending': (completed: false, confirmedMs: 1280),
              'nearLate': (completed: false, confirmedMs: 1280),
              'pausedNear': (completed: false, confirmedMs: 1280),
              'nearFresh': (completed: true, confirmedMs: 1600),
              'away': (completed: false, confirmedMs: 1120),
              'endpoint': (completed: true, confirmedMs: 1600),
              'rejected': (completed: true, confirmedMs: 1600),
              'normalNear': (completed: false, confirmedMs: 99600),
              'normalAway': (completed: false, confirmedMs: 99400),
            };
        for (final entry in expected.entries) {
          final res = await runNearEndMode(entry.key);
          expect(res.completed, entry.value.completed, reason: entry.key);
          expect(res.confirmedMs, entry.value.confirmedMs, reason: entry.key);
          if (entry.key == 'pausedNear') {
            expect(res.playing, isFalse, reason: 'pausedNear stays paused');
          }
        }
      },
    );
  });
}

class _R9AppearancePrefsStore extends InMemorySharedPreferencesStore {
  _R9AppearancePrefsStore() : super.withData(<String, Object>{});

  String? refuseOnceKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (refuseOnceKey != null && key == refuseOnceKey) {
      refuseOnceKey = null;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

class _R8JournalPrefsStore extends InMemorySharedPreferencesStore {
  _R8JournalPrefsStore() : super.withData(<String, Object>{});

  String? gateKey;
  String? refuseRemoveOnceKey;
  final Completer<void> entered = Completer<void>();
  final Completer<bool> proceed = Completer<bool>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (gateKey != null && key == gateKey) {
      gateKey = null;
      entered.complete();
      if (!await proceed.future) {
        throw StateError('rejected gated preference write');
      }
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (refuseRemoveOnceKey != null && key == refuseRemoveOnceKey) {
      refuseRemoveOnceKey = null;
      return false;
    }
    return super.remove(key);
  }
}

class _R7GatedPrefsStore extends InMemorySharedPreferencesStore {
  _R7GatedPrefsStore() : super.withData(<String, Object>{});

  String? refuseOnceKey;
  String? gateKey;
  final Completer<void> entered = Completer<void>();
  final Completer<bool> proceed = Completer<bool>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (refuseOnceKey != null && key == refuseOnceKey) {
      refuseOnceKey = null;
      return false;
    }
    if (gateKey != null && key == gateKey) {
      gateKey = null;
      entered.complete();
      if (!await proceed.future) {
        throw StateError('rejected gated preference write');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

class _R6RejectArchiveDisk extends InMemoryStorageFileStore {
  bool rejectArchives = false;

  @override
  void writeBytesSync(String name, List<int> bytes) {
    if (rejectArchives && name.startsWith('watch_history_corrupt_')) {
      throw const FileSystemException('temporary archive write failure');
    }
    super.writeBytesSync(name, bytes);
  }
}

class _R6SelectivePrefsStore extends InMemorySharedPreferencesStore {
  _R6SelectivePrefsStore() : super.withData(<String, Object>{});

  String? refuseOnceKey;
  String? refuseKey;
  String? throwKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (refuseOnceKey != null && key == refuseOnceKey) {
      refuseOnceKey = null;
      return Future<bool>.value(false);
    }
    if (refuseKey != null && key == refuseKey) {
      return Future<bool>.value(false);
    }
    if (throwKey != null && key == throwKey) {
      return Future<bool>.error(PlatformException(code: 'write_failed'));
    }
    return super.setValue(valueType, key, value);
  }
}

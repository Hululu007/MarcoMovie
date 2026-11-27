// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;
import 'package:media_kit/media_kit.dart';

import 'ohos_runtime.dart';
import 'windows_tray_service.dart';

/// User-selectable Windows desktop playback engine.
///
/// - [mpv]: `media_kit` (`libmpv`) pipeline with Anime4K real-time shaders,
///   custom HDR tone-mapping, and parametric EQ vocal enhancement filters.
/// - [mdk]: `libmdk` (`fvp`) native Direct3D 11 / MFT / DXVA zero-copy hardware
///   decoder & renderer, specifically tuned for Intel/AMD integrated GPUs (`核显`)
///   and thin-and-light Windows laptops.
enum WindowsPlaybackEngine {
  mpv(
    id: 'mpv',
    labelZh: 'MPV 旗舰画质（libmpv）',
    shortLabel: 'MPV',
    descriptionZh:
        '支持 Anime4K 实时超分、自定义 HDR 色调映射与人声均衡增强，适合独立显卡与进阶画质调校',
  ),
  mdk(
    id: 'mdk',
    labelZh: 'MDK 核显兼容（推荐核显）',
    shortLabel: 'MDK',
    descriptionZh:
        '原生 D3D11 / MFT / DXVA 零拷贝硬件解码，GPU 与显存占用极低，专为 Intel/AMD 核显及老显卡流畅播放 4K/HDR 优化',
  );

  static const String prefKey = 'windows_playback_engine';

  final String id;
  final String labelZh;
  final String shortLabel;
  final String descriptionZh;

  const WindowsPlaybackEngine({
    required this.id,
    required this.labelZh,
    required this.shortLabel,
    required this.descriptionZh,
  });

  static WindowsPlaybackEngine fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    if (normalized == 'mdk' || normalized == 'fvp') {
      return WindowsPlaybackEngine.mdk;
    }
    return WindowsPlaybackEngine.mpv;
  }
}

/// Snapshot of MDK media metadata abstracted for deterministic unit testing.
class MdkMediaSnapshot {
  final int durationMs;
  final int videoWidth;
  final int videoHeight;
  final List<VideoTrack> videoTracks;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;

  const MdkMediaSnapshot({
    this.durationMs = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.videoTracks = const <VideoTrack>[],
    this.audioTracks = const <AudioTrack>[],
    this.subtitleTracks = const <SubtitleTrack>[],
  });
}

/// Abstract native backend interface wrapping `fvp/mdk.dart`'s [mdk.Player] so
/// [MdkPlatformPlayer] can be thoroughly tested without a live D3D11 GPU.
abstract class MdkNativeBackend {
  ValueListenable<int?> get textureIdListenable;
  Stream<({int oldStatus, int newStatus})> get onStatusChanged;
  Stream<mdk.PlaybackState> get onStateChanged;
  Stream<({int error, String category, String detail})> get onEvent;

  int get positionMs;
  int get bufferedMs;
  bool get isLive;
  MdkMediaSnapshot readMediaSnapshot();

  set media(String uri);
  set state(mdk.PlaybackState value);
  set playbackRate(double value);
  set volume(double value);
  set mute(bool value);
  set loop(int value);
  set videoDecoders(List<String> decoders);
  set activeAudioTracks(List<int> tracks);
  set activeSubtitleTracks(List<int> tracks);
  set activeVideoTracks(List<int> tracks);

  void setProperty(String key, String value);
  void setBufferRange({int min = -1, int max = -1, bool drop = false});
  void setMediaForType(String uri, mdk.MediaType type);
  Future<int> prepare({int position = 0});
  Future<int> seek({required int position, required mdk.SeekFlag flags});
  Future<int> updateTexture({int? width, int? height});
  Future<void> disposeAsync();
}

/// Optional capability interface implemented by real MDK backends (and
/// targeted tests) to expose native subtitle cue text callbacks and immediate
/// cancellation of pre-first-frame texture waits without breaking legacy
/// `MdkNativeBackend` test fakes.
abstract class MdkExtendedNativeBackend {
  Stream<({double startSec, double endSec, List<String> lines})>
      get onSubtitleText;
  void cancelPendingTextureWait();
}

class _RealMdkNativeBackend implements MdkNativeBackend, MdkExtendedNativeBackend {
  final mdk.Player _inner = mdk.Player();
  final StreamController<({int oldStatus, int newStatus})> _statusCtl =
      StreamController<({int oldStatus, int newStatus})>.broadcast();
  final StreamController<mdk.PlaybackState> _stateCtl =
      StreamController<mdk.PlaybackState>.broadcast();
  final StreamController<({int error, String category, String detail})>
      _eventCtl = StreamController<
          ({int error, String category, String detail})>.broadcast();
  final StreamController<({double startSec, double endSec, List<String> lines})>
      _subtitleCtl = StreamController<
          ({double startSec, double endSec, List<String> lines})>.broadcast();
  late final StreamSubscription<dynamic> _statusSub;
  late final StreamSubscription<dynamic> _stateSub;
  late final StreamSubscription<dynamic> _eventSub;
  Completer<void>? _pendingTextureSizeCancel;
  bool _disposed = false;

  _RealMdkNativeBackend() {
    _statusSub = _inner.onMediaStatus.listen((ev) {
      if (!_statusCtl.isClosed) {
        _statusCtl.add((
          oldStatus: ev.oldValue.rawValue,
          newStatus: ev.newValue.rawValue,
        ));
      }
    });
    _stateSub = _inner.onStateChanged.listen((ev) {
      if (!_stateCtl.isClosed) {
        _stateCtl.add(ev.newValue);
      }
    });
    _eventSub = _inner.onEvent.listen((ev) {
      if (!_eventCtl.isClosed) {
        _eventCtl.add((
          error: ev.error,
          category: ev.category,
          detail: ev.detail,
        ));
      }
    });
    try {
      _inner.onSubtitleText((start, end, text) {
        if (_disposed || _subtitleCtl.isClosed) return;
        final lines = text
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        _subtitleCtl.add((
          startSec: start,
          endSec: end,
          lines: lines,
        ));
      });
    } catch (_) {}
  }

  @override
  Stream<({double startSec, double endSec, List<String> lines})>
      get onSubtitleText => _subtitleCtl.stream;

  @override
  ValueListenable<int?> get textureIdListenable => _inner.textureId;

  @override
  Stream<({int oldStatus, int newStatus})> get onStatusChanged =>
      _statusCtl.stream;

  @override
  Stream<mdk.PlaybackState> get onStateChanged => _stateCtl.stream;

  @override
  Stream<({int error, String category, String detail})> get onEvent =>
      _eventCtl.stream;

  @override
  int get positionMs => _disposed ? 0 : _inner.position;

  @override
  int get bufferedMs => _disposed ? 0 : _inner.buffered();

  @override
  bool get isLive => _disposed ? false : _inner.isLive;

  @override
  MdkMediaSnapshot readMediaSnapshot() {
    if (_disposed) return const MdkMediaSnapshot();
    final info = _inner.mediaInfo;
    int width = 0;
    int height = 0;
    final videoTracks = <VideoTrack>[VideoTrack.auto()];
    final rawVideos = info.video ?? const <mdk.VideoStreamInfo>[];
    for (int i = 0; i < rawVideos.length; i++) {
      final v = rawVideos[i];
      final w = v.codec.width;
      final h = v.codec.height;
      final rotated = v.rotation == 90 || v.rotation == 270;
      final displayW = rotated ? h : w;
      final displayH = rotated ? w : h;
      if (width <= 0 && displayW > 0 && displayH > 0) {
        width = displayW;
        height = displayH;
      }
      final title = (v.metadata['title'] ?? '').trim();
      final lang = (v.metadata['language'] ?? '').trim();
      final codec = v.codec.codec.trim();
      videoTracks.add(
        VideoTrack(
          '$i',
          title.isNotEmpty ? title : 'Video ${i + 1}',
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
          w: displayW > 0 ? displayW : null,
          h: displayH > 0 ? displayH : null,
        ),
      );
    }

    final audioTracks = <AudioTrack>[AudioTrack.auto()];
    final rawAudios = info.audio ?? const <mdk.AudioStreamInfo>[];
    for (int i = 0; i < rawAudios.length; i++) {
      final a = rawAudios[i];
      final title = (a.metadata['title'] ?? '').trim();
      final lang = (a.metadata['language'] ?? '').trim();
      final codec = a.codec.codec.trim();
      final channels = a.codec.channels > 0 ? '${a.codec.channels}ch' : null;
      audioTracks.add(
        AudioTrack(
          '$i',
          title.isNotEmpty ? title : (lang.isNotEmpty ? lang : '音轨 ${i + 1}'),
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
          channels: channels,
        ),
      );
    }

    final subtitleTracks = <SubtitleTrack>[
      SubtitleTrack.auto(),
      SubtitleTrack.no(),
    ];
    final rawSubs = info.subtitle ?? const <mdk.SubtitleStreamInfo>[];
    for (int i = 0; i < rawSubs.length; i++) {
      final s = rawSubs[i];
      final title = (s.metadata['title'] ?? '').trim();
      final lang = (s.metadata['language'] ?? '').trim();
      final codec = s.codec.codec.trim();
      subtitleTracks.add(
        SubtitleTrack(
          '$i',
          title.isNotEmpty ? title : (lang.isNotEmpty ? lang : '字幕 ${i + 1}'),
          lang.isNotEmpty ? lang : null,
          codec: codec.isNotEmpty ? codec : null,
        ),
      );
    }

    return MdkMediaSnapshot(
      durationMs: math.max(0, info.duration),
      videoWidth: width,
      videoHeight: height,
      videoTracks: videoTracks,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
    );
  }

  @override
  set media(String uri) {
    if (!_disposed) _inner.media = uri;
  }

  @override
  set state(mdk.PlaybackState value) {
    if (!_disposed) _inner.state = value;
  }

  @override
  set playbackRate(double value) {
    if (!_disposed) _inner.playbackRate = value;
  }

  @override
  set volume(double value) {
    if (!_disposed) _inner.volume = value;
  }

  @override
  set mute(bool value) {
    if (!_disposed) _inner.mute = value;
  }

  @override
  set loop(int value) {
    if (!_disposed) _inner.loop = value;
  }

  @override
  set videoDecoders(List<String> decoders) {
    if (!_disposed) _inner.videoDecoders = decoders;
  }

  @override
  set activeAudioTracks(List<int> tracks) {
    if (!_disposed) _inner.activeAudioTracks = tracks;
  }

  @override
  set activeSubtitleTracks(List<int> tracks) {
    if (!_disposed) _inner.activeSubtitleTracks = tracks;
  }

  @override
  set activeVideoTracks(List<int> tracks) {
    if (!_disposed) _inner.activeVideoTracks = tracks;
  }

  @override
  void setProperty(String key, String value) {
    if (!_disposed) _inner.setProperty(key, value);
  }

  @override
  void setBufferRange({int min = -1, int max = -1, bool drop = false}) {
    if (!_disposed) _inner.setBufferRange(min: min, max: max, drop: drop);
  }

  @override
  void setMediaForType(String uri, mdk.MediaType type) {
    if (!_disposed) _inner.setMedia(uri, type);
  }

  @override
  Future<int> prepare({int position = 0}) {
    if (_disposed) return Future<int>.value(-10);
    return _inner.prepare(position: position);
  }

  @override
  Future<int> seek({required int position, required mdk.SeekFlag flags}) {
    if (_disposed) return Future<int>.value(-10);
    return _inner.seek(position: position, flags: flags);
  }

  @override
  Future<int> updateTexture({int? width, int? height}) {
    return updateTextureCancellable(width: width, height: height);
  }

  /// Splits `ReleaseRT` and `CreateRT` across an explicit cancellation / native
  /// teardown checkpoint so a delayed `ReleaseRT` reply during episode switch
  /// or window close can NEVER invoke a new `CreateRT` after disposal or native
  /// window destruction has begun.
  Future<int> updateTextureCancellable({
    int? width,
    int? height,
    bool Function()? shouldCancel,
  }) async {
    bool cancelled() =>
        _disposed ||
        WindowsTrayService.isNativeDestroyStarted ||
        (shouldCancel?.call() ?? false);
    if ((_inner.textureId.value ?? -1) >= 0) {
      await _inner.updateTexture(width: -1);
    }
    if ((width != null && width <= 0) || (height != null && height <= 0)) {
      return -1;
    }
    if (cancelled()) {
      return -1;
    }
    final sizeCancel = Completer<void>();
    final prevCancel = _pendingTextureSizeCancel;
    if (prevCancel != null && !prevCancel.isCompleted) {
      prevCancel.complete();
    }
    _pendingTextureSizeCancel = sizeCancel;
    final dynamic sizeFuture = _inner.textureSize;
    unawaited(
      (sizeFuture as Future<dynamic>).then<void>((_) {}, onError: (_) {}),
    );
    dynamic size;
    try {
      size = await Future.any<dynamic>(<Future<dynamic>>[
        sizeFuture,
        sizeCancel.future.then<dynamic>((_) => null),
      ]);
    } finally {
      if (identical(_pendingTextureSizeCancel, sizeCancel)) {
        _pendingTextureSizeCancel = null;
      }
    }
    if (size == null || cancelled()) {
      return -1;
    }
    return _inner.updateTexture(width: width, height: height);
  }

  /// Safely unblocks a pre-first-frame `updateTexture()` that is still awaiting
  /// `_videoSize.future` without freeing the native `mdkPlayerAPI*` handle. If
  /// `CreateRT` IPC is already in flight, setting `media = ''` does not delete
  /// the handle so the in-flight texture completes safely before disposal.
  @override
  void cancelPendingTextureWait() {
    final pendingCancel = _pendingTextureSizeCancel;
    _pendingTextureSizeCancel = null;
    if (pendingCancel != null && !pendingCancel.isCompleted) {
      pendingCancel.complete();
    }
    if (_disposed) return;
    try {
      _inner.state = mdk.PlaybackState.stopped;
      if (_inner.textureId.value == null) {
        _inner.media = '';
      }
    } catch (_) {}
  }

  @override
  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    final pendingCancel = _pendingTextureSizeCancel;
    _pendingTextureSizeCancel = null;
    if (pendingCancel != null && !pendingCancel.isCompleted) {
      pendingCancel.complete();
    }
    try {
      _inner.onSubtitleText(null);
    } catch (_) {}
    await _statusSub.cancel();
    await _stateSub.cancel();
    await _eventSub.cancel();
    await _statusCtl.close();
    await _stateCtl.close();
    await _eventCtl.close();
    await _subtitleCtl.close();
    // If native window destruction has already started (e.g. bounded exit timed
    // out while a slow texture callback was still in flight), do NOT issue new
    // Flutter MethodChannel IPC (`ReleaseRT`) against a tearing-down messenger
    // or delete `mdkPlayerAPI*` ahead of `~FvpPlugin()`; `~FvpPlugin()` safely
    // destroys remaining TexturePlayer wrappers on the still-live handle before
    // FlutterEngineShutdown terminates the isolate.
    if (WindowsTrayService.isNativeDestroyStarted) {
      try {
        _inner.state = mdk.PlaybackState.stopped;
      } catch (_) {}
      return;
    }
    await _inner.disposeAsync();
  }
}

/// Windows `libmdk` (`fvp`) implementation of `media_kit`'s [PlatformPlayer].
///
/// Renders frames zero-copy through Flutter's GPU `TextureRegistry` via D3D11 /
/// MFT / DXVA hardware decoders, tuned specifically for Intel UHD / Iris Xe /
/// older Intel HD and AMD Radeon integrated GPUs (`核显`) so 4K/HDR & netdisk
/// streams play smoothly with low GPU/CPU footprint and full compatibility with
/// PlayerScreen (danmu, seek, speed, tracks, subtitles, resume, live streams).
class MdkPlatformPlayer extends PlatformPlayer {
  /// Default Windows decoder priority tuned for integrated GPUs (`核显`) first
  /// (MFT D3D11 -> FFmpeg D3D11VA -> DXVA2 for older iGPUs -> CUDA -> CPU/AV1).
  static const List<String> defaultIgpuDecoders = <String>[
    'MFT:d3d=11',
    'D3D11',
    'DXVA',
    'CUDA',
    'FFmpeg',
    'dav1d',
  ];

  /// Compatibility decoder priority for older Intel HD 4000–620 / older AMD APU
  /// drivers where DXVA2 / D3D11 copy path avoids SRV driver crashes.
  static const List<String> legacyIgpuCompatDecoders = <String>[
    'DXVA',
    'D3D11',
    'MFT:d3d=11',
    'FFmpeg',
    'dav1d',
  ];

  /// Default Apple iOS / iPadOS hardware decoder chain (`VideoToolbox` zero-copy
  /// Metal `IOSurface` + built-in Metal Dolby Vision Profile 5/7/8 `ICtCp`
  /// reshape & HDR10 tone-mapping).
  static const List<String> defaultIosDecoders = <String>[
    'VT',
    'FFmpeg',
    'dav1d',
  ];

  /// Compatibility iOS `VideoToolbox` copy-back chain.
  static const List<String> compatIosDecoders = <String>[
    'VT:copy=1',
    'VT',
    'FFmpeg',
    'dav1d',
  ];

  static bool _globalInitialized = false;

  /// Whether Apple iOS / iPadOS Metal `mdk.framework` (`fvp`) is enabled.
  static bool get isIosSupported => true;

  /// Resolves the decoder priority list for the user's playback strategy.
  static List<String> decodersForKernelStrategy(
    String kernelStrategy, {
    TargetPlatform? platform,
  }) {
    final effectivePlatform = platform ?? defaultTargetPlatform;
    final isCompat = kernelStrategy.trim().toLowerCase() == 'ijk';
    if (!kIsWeb && effectivePlatform == TargetPlatform.iOS) {
      return isCompat ? compatIosDecoders : defaultIosDecoders;
    }
    if (isCompat) {
      return legacyIgpuCompatDecoders;
    }
    return defaultIgpuDecoders;
  }

  static String _resolveWindowsSubtitleFont() {
    if (kIsWeb || !Platform.isWindows) return '';
    const candidates = <String>[
      r'C:\Windows\Fonts\msyh.ttc',
      r'C:\Windows\Fonts\msyh.ttf',
      r'C:\Windows\Fonts\simhei.ttf',
      r'C:\Windows\Fonts\simsun.ttc',
    ];
    for (final path in candidates) {
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return '';
  }

  static String _resolveIosSubtitleFont() {
    if (kIsWeb || !Platform.isIOS) return '';
    const candidates = <String>[
      '/System/Library/Fonts/PingFang.ttc',
      '/System/Library/Fonts/CoreUI/PingFang.ttc',
      '/System/Library/Fonts/LanguageSupport/PingFang.ttc',
    ];
    for (final path in candidates) {
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return '';
  }

  /// Idempotently initializes `fvp` / `libmdk` global options on Windows & iOS
  /// (activating bundled MDK key for commercial Metal Dolby Vision / HDR + D3D11
  /// hardware pipelines and CJK subtitle font fallback).
  static void ensureInitialized() {
    if (_globalInitialized ||
        kIsWeb ||
        OhosRuntime.isOhos ||
        (!Platform.isWindows && !Platform.isIOS) ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _globalInitialized = true;
    try {
      if (Platform.isIOS) {
        final iosFont = _resolveIosSubtitleFont();
        fvp.registerWith(
          options: <String, dynamic>{
            'platforms': <String>['ios'],
            'fastSeek': true,
            'video.decoders': defaultIosDecoders,
            'global': <String, Object>{
              'log': 'warning',
              'subtitle.fonts.file': iosFont,
            },
          },
        );
        return;
      }
      final fontPath = _resolveWindowsSubtitleFont();
      fvp.registerWith(
        options: <String, dynamic>{
          'platforms': <String>['windows'],
          'fastSeek': true,
          'video.decoders': defaultIgpuDecoders,
          'global': <String, Object>{
            'd3d11.sync.cpu': 1,
            'log': 'warning',
            if (fontPath.isNotEmpty) 'subtitle.fonts.file': fontPath,
          },
        },
      );
    } catch (e) {
      debugPrint('MdkPlatformPlayer.ensureInitialized warning: $e');
    }
  }

  final MdkNativeBackend _backend;
  final Map<String, String> _properties = <String, String>{};
  final String _initialKernelStrategy;
  StreamSubscription<({int oldStatus, int newStatus})>? _statusSub;
  StreamSubscription<mdk.PlaybackState>? _stateSub;
  StreamSubscription<({int error, String category, String detail})>? _eventSub;
  StreamSubscription<({double startSec, double endSec, List<String> lines})>?
      _subtitleSub;
  Timer? _positionTimer;
  int _openGeneration = 0;
  int _texturePreparedGeneration = -1;
  Future<void>? _textureUpdateFuture;
  Completer<void>? _pendingPrepareCancel;
  Completer<void>? _pendingTextureWaitCancel;
  double? _activeSubtitleEndSec;
  bool _disposed = false;

  /// Returns true when [codec] denotes a graphical/bitmap subtitle stream
  /// (e.g. Blu-ray PGS, DVD VobSub, DVB-SUB) from which plain text cannot be
  /// extracted without OCR.
  static bool isBitmapSubtitleCodec(String? codec) {
    final c = (codec ?? '').trim().toLowerCase();
    if (c.isEmpty) return false;
    return c.contains('pgs') ||
        c.contains('dvd_subtitle') ||
        c.contains('vobsub') ||
        c.contains('dvb_subtitle') ||
        c.contains('xsub') ||
        c.contains('bitmap') ||
        c == 'sup' ||
        c == 's_hdmv/pgs';
  }

  bool get isCurrentSubtitleTrackBitmap =>
      isBitmapSubtitleCodec(state.track.subtitle.codec);
  bool _acceptingBackendEvents = true;
  bool _userRequestedStop = false;
  bool _demuxerReachedEnd = false;
  bool _isLiveHint = false;
  String _activeVideoDecoderName = '';

  MdkPlatformPlayer({
    super.configuration = const PlayerConfiguration(),
    String kernelStrategy = 'exo',
    MdkNativeBackend? debugBackend,
  })  : _initialKernelStrategy = kernelStrategy,
        _backend = debugBackend ?? _createRealBackend() {
    _configureBaselineProperties(_initialKernelStrategy);
    _attachBackendListeners();
    configuration.ready?.call();
  }

  static MdkNativeBackend _createRealBackend() {
    ensureInitialized();
    return _RealMdkNativeBackend();
  }

  ValueListenable<int?> get textureIdListenable => _backend.textureIdListenable;
  int? get textureId => _backend.textureIdListenable.value;
  String get activeVideoDecoderName => _activeVideoDecoderName;
  Map<String, String> get properties =>
      Map<String, String>.unmodifiable(_properties);

  void _configureBaselineProperties(String kernelStrategy) {
    _backend.videoDecoders = decodersForKernelStrategy(kernelStrategy);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      // Crucial for Windows Intel/AMD iGPU drivers: avoid D3D11 SRV format mismatch.
      // On iOS, leave unset so `VT` binds 10-bit `P010` `IOSurface` zero-copy into Metal!
      _backend.setProperty('video.decoder', 'shader_resource=0');
    }
    _backend.setProperty('keep_open', '1');
    _backend.setProperty('avformat.strict', 'experimental');
    _backend.setProperty('avformat.safe', '0');
    _backend.setProperty('avformat.extension_picky', '0');
    _backend.setProperty('avformat.allowed_segment_extensions', 'ALL');
    _backend.setProperty('avformat.rtsp_transport', 'tcp');
    _backend.setProperty('avio.reconnect', '1');
    _backend.setProperty('avio.reconnect_streamed', '1');
    _backend.setProperty('avio.reconnect_on_network_error', '1');
    _backend.setProperty('avio.reconnect_delay_max', '7');
    _backend.setProperty(
      'avio.protocol_whitelist',
      'file,ftp,rtmp,http,https,tls,rtp,tcp,udp,crypto,httpproxy,data,concatf,concat,subfile',
    );
    _applyBufferPolicy(kernelStrategy: kernelStrategy, isLive: _isLiveHint);
  }

  void _applyBufferPolicy({
    required String kernelStrategy,
    required bool isLive,
  }) {
    if (isLive) {
      _backend.setBufferRange(min: 500, max: 3000, drop: true);
      _backend.setProperty('avformat.analyzeduration', '1000000');
      _backend.setProperty('avformat.probesize', '1000000');
      return;
    }
    switch (kernelStrategy.trim().toLowerCase()) {
      case 'mpv':
        _backend.setBufferRange(min: 2000, max: 32000, drop: false);
        break;
      case 'ijk':
        _backend.setBufferRange(min: 2000, max: 20000, drop: false);
        break;
      default:
        _backend.setBufferRange(min: 1500, max: 16000, drop: false);
        break;
    }
  }

  void _attachBackendListeners() {
    _statusSub = _backend.onStatusChanged.listen((ev) {
      if (_disposed || !_acceptingBackendEvents) return;
      final oldS = mdk.MediaStatus(ev.oldStatus);
      final newS = mdk.MediaStatus(ev.newStatus);

      if (!oldS.test(mdk.MediaStatus.loaded) &&
          newS.test(mdk.MediaStatus.loaded)) {
        _syncMediaSnapshot();
        unawaited(_refreshTextureSafely(generation: _openGeneration));
      }

      final nowBuffering = newS.test(mdk.MediaStatus.buffering) ||
          newS.test(mdk.MediaStatus.stalled);
      final wasBuffering = oldS.test(mdk.MediaStatus.buffering) ||
          oldS.test(mdk.MediaStatus.stalled);
      if (nowBuffering != wasBuffering) {
        state = state.copyWith(buffering: nowBuffering);
        bufferingController.add(nowBuffering);
      } else if (newS.test(mdk.MediaStatus.buffered) && state.buffering) {
        state = state.copyWith(buffering: false);
        bufferingController.add(false);
      }

      if (!newS.test(mdk.MediaStatus.end)) {
        _demuxerReachedEnd = false;
      } else if (!oldS.test(mdk.MediaStatus.end) &&
          !newS.test(mdk.MediaStatus.seeking)) {
        _demuxerReachedEnd = true;
        final posMs = math.max(0, _backend.positionMs);
        final bufMs = math.max(0, _backend.bufferedMs);
        final durMs = state.duration.inMilliseconds;
        // In libmdk, MediaStatus.end is set as soon as the demuxer reaches EOF
        // (e.g. after seeking into the last 16-32s buffer window), while frames
        // are still buffered and playing. Only mark completed immediately when
        // no buffered tail remains to be played; otherwise _emitPositionAndBuffer
        // completes playback once the clock reaches the end of the media.
        final stillHasBufferedPlayback =
            bufMs > 500 ||
            (newS.test(mdk.MediaStatus.buffered) &&
                durMs > 2000 &&
                posMs < durMs - 1500);
        if (!stillHasBufferedPlayback) {
          _markPlaybackCompleted();
        }
      }

      if (!oldS.test(mdk.MediaStatus.invalid) &&
          newS.test(mdk.MediaStatus.invalid)) {
        _stopPositionTimer();
        state = state.copyWith(playing: false, buffering: false);
        playingController.add(false);
        bufferingController.add(false);
        errorController.add('MDK failed to open or decode media stream');
      }
    });

    _stateSub = _backend.onStateChanged.listen((nextState) {
      if (_disposed) return;
      final playing = nextState == mdk.PlaybackState.playing;
      if (playing) {
        _startPositionTimer();
      } else {
        _stopPositionTimer();
      }
      if (nextState == mdk.PlaybackState.stopped &&
          _acceptingBackendEvents &&
          !_userRequestedStop &&
          !state.completed &&
          _demuxerReachedEnd) {
        final posMs = math.max(0, _backend.positionMs);
        final bufDeltaMs = math.max(0, _backend.bufferedMs);
        final durMs = state.duration.inMilliseconds;
        if (bufDeltaMs <= 500 &&
            (durMs <= 0 || posMs >= durMs - 1500)) {
          final pos = Duration(milliseconds: posMs);
          final buf = Duration(milliseconds: posMs + bufDeltaMs);
          state = state.copyWith(position: pos, buffer: buf);
          positionController.add(pos);
          bufferController.add(buf);
          _markPlaybackCompleted();
          return;
        }
      }
      if (state.playing != playing) {
        state = state.copyWith(
          playing: playing,
          completed: playing ? false : state.completed,
        );
        playingController.add(playing);
      }
    });

    _eventSub = _backend.onEvent.listen((ev) {
      if (_disposed || !_acceptingBackendEvents) return;
      if (ev.error < 0) {
        if (ev.category == 'reader.open' ||
            ev.category == 'decoder.video' ||
            ev.category == 'reader.read') {
          final detail = ev.detail.trim();
          errorController.add(
            detail.isNotEmpty
                ? 'MDK ${ev.category}: $detail (${ev.error})'
                : 'MDK failed to open stream (${ev.category}: ${ev.error})',
          );
        }
      } else if (ev.category == 'decoder.video' && ev.detail.isNotEmpty) {
        _activeVideoDecoderName = ev.detail;
        _syncMediaSnapshot();
      } else if (ev.category == 'reader.buffering') {
        _emitPositionAndBuffer();
      }
    });

    if (_backend is MdkExtendedNativeBackend) {
      final ext = _backend as MdkExtendedNativeBackend;
      _subtitleSub = ext.onSubtitleText.listen((cue) {
        if (_disposed || !_acceptingBackendEvents) return;
        final lines = cue.lines
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        _activeSubtitleEndSec =
            (lines.isNotEmpty && cue.endSec > 0) ? cue.endSec : null;
        state = state.copyWith(subtitle: lines);
        subtitleController.add(lines);
      });
    }
  }

  void _clearActiveSubtitleLines() {
    _activeSubtitleEndSec = null;
    if (state.subtitle.isNotEmpty) {
      state = state.copyWith(subtitle: const <String>[]);
      subtitleController.add(const <String>[]);
    }
  }

  Future<void> _refreshTextureSafely({int? generation}) async {
    final targetGen = generation ?? _openGeneration;
    if (_disposed ||
        targetGen != _openGeneration ||
        WindowsTrayService.isNativeDestroyStarted) {
      return;
    }
    final cancel = Completer<void>();
    final prevCancel = _pendingTextureWaitCancel;
    if (prevCancel != null && !prevCancel.isCompleted) {
      prevCancel.complete();
    }
    _pendingTextureWaitCancel = cancel;

    Future<void> raceWait(Future<void> op) {
      return Future.any<void>(<Future<void>>[
        op,
        cancel.future,
      ]);
    }

    try {
      final previous = _textureUpdateFuture;
      if (_texturePreparedGeneration == targetGen) {
        if (previous != null) {
          try {
            await raceWait(previous);
          } catch (_) {}
        }
        return;
      }
      if (previous != null) {
        try {
          await raceWait(previous);
        } catch (_) {}
        if (_disposed ||
            targetGen != _openGeneration ||
            _texturePreparedGeneration == targetGen ||
            WindowsTrayService.isNativeDestroyStarted) {
          return;
        }
      }
      _texturePreparedGeneration = targetGen;
      final op = () async {
        try {
          if (_backend is _RealMdkNativeBackend) {
            await (_backend as _RealMdkNativeBackend).updateTextureCancellable(
              shouldCancel: () =>
                  _disposed ||
                  targetGen != _openGeneration ||
                  WindowsTrayService.isNativeDestroyStarted,
            );
          } else {
            await _backend.updateTexture();
          }
        } catch (e) {
          if (_texturePreparedGeneration == targetGen) {
            _texturePreparedGeneration = -1;
          }
          debugPrint('MdkPlatformPlayer updateTexture warning: $e');
        }
      }();
      _textureUpdateFuture = op;
      unawaited(op.whenComplete(() {
        if (identical(_textureUpdateFuture, op)) {
          _textureUpdateFuture = null;
        }
      }));
      await raceWait(op);
    } finally {
      if (identical(_pendingTextureWaitCancel, cancel)) {
        _pendingTextureWaitCancel = null;
      }
    }
  }

  void _syncMediaSnapshot() {
    if (_disposed) return;
    final snap = _backend.readMediaSnapshot();
    if (snap.durationMs > 0) {
      final dur = Duration(milliseconds: snap.durationMs);
      if (state.duration != dur) {
        state = state.copyWith(duration: dur);
        durationController.add(dur);
      }
    }
    if (snap.videoWidth > 0 && snap.videoHeight > 0) {
      if (state.width != snap.videoWidth || state.height != snap.videoHeight) {
        state = state.copyWith(
          width: snap.videoWidth,
          height: snap.videoHeight,
        );
        widthController.add(snap.videoWidth);
        heightController.add(snap.videoHeight);
      }
    }
    if (snap.videoTracks.isNotEmpty ||
        snap.audioTracks.isNotEmpty ||
        snap.subtitleTracks.isNotEmpty) {
      final nextTracks = Tracks(
        video: snap.videoTracks.isNotEmpty
            ? snap.videoTracks
            : <VideoTrack>[VideoTrack.auto()],
        audio: snap.audioTracks.isNotEmpty
            ? snap.audioTracks
            : <AudioTrack>[AudioTrack.auto()],
        subtitle: snap.subtitleTracks.isNotEmpty
            ? snap.subtitleTracks
            : <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()],
      );
      final activeVideo = nextTracks.video.length > 1
          ? nextTracks.video[1]
          : VideoTrack.auto();
      final activeAudio = nextTracks.audio.length > 1
          ? nextTracks.audio[1]
          : AudioTrack.auto();
      final activeSub = nextTracks.subtitle.length > 2
          ? nextTracks.subtitle[2]
          : state.track.subtitle;
      final nextTrack = Track(
        video: activeVideo,
        audio: activeAudio,
        subtitle: activeSub,
      );
      state = state.copyWith(tracks: nextTracks, track: nextTrack);
      tracksController.add(nextTracks);
      trackController.add(nextTrack);
    }
  }

  void _startPositionTimer() {
    if (_disposed) return;
    if (_positionTimer?.isActive ?? false) return;
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _emitPositionAndBuffer(),
    );
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  void _markPlaybackCompleted() {
    if (_disposed || state.completed) return;
    _demuxerReachedEnd = false;
    _stopPositionTimer();
    state = state.copyWith(
      playing: false,
      buffering: false,
      completed: true,
    );
    playingController.add(false);
    bufferingController.add(false);
    completedController.add(true);
  }

  void _emitPositionAndBuffer() {
    if (_disposed) return;
    final posMs = math.max(0, _backend.positionMs);
    final bufDeltaMs = math.max(0, _backend.bufferedMs);
    final pos = Duration(milliseconds: posMs);
    final buf = Duration(milliseconds: posMs + bufDeltaMs);
    state = state.copyWith(position: pos, buffer: buf);
    positionController.add(pos);
    bufferController.add(buf);
    if (_activeSubtitleEndSec != null &&
        (posMs / 1000.0) > _activeSubtitleEndSec! + 0.15) {
      _clearActiveSubtitleLines();
    }
    if (state.duration <= Duration.zero && !_backend.isLive) {
      final snap = _backend.readMediaSnapshot();
      if (snap.durationMs > 0) {
        final dur = Duration(milliseconds: snap.durationMs);
        state = state.copyWith(duration: dur);
        durationController.add(dur);
      }
    }
    if (_demuxerReachedEnd &&
        state.playing &&
        !state.completed &&
        state.duration > Duration.zero &&
        bufDeltaMs <= 250 &&
        posMs >= state.duration.inMilliseconds - 300) {
      _markPlaybackCompleted();
    }
  }

  /// Compatibility shim for `PlayerScreen`'s libmpv property hints (`user-agent`,
  /// `referrer`, `tls-verify`, `hwdec`, buffer strategy, etc.).
  Future<void> setProperty(String key, String value) async {
    if (_disposed) return;
    _properties[key] = value;
    switch (key) {
      case 'tls-verify':
        final liveLike = value.trim().toLowerCase() == 'no';
        _isLiveHint = liveLike;
        _backend.setProperty('avio.tls_verify', liveLike ? '0' : '1');
        _applyBufferPolicy(
          kernelStrategy: _initialKernelStrategy,
          isLive: liveLike,
        );
        break;
      case 'hwdec':
        final compat = value.contains('copy');
        _backend.videoDecoders = decodersForKernelStrategy(
          compat ? 'ijk' : 'exo',
        );
        break;
      case 'af':
        var cleanAf = value.trim();
        if (cleanAf.startsWith('lavfi=[') && cleanAf.endsWith(']')) {
          cleanAf = cleanAf.substring('lavfi=['.length, cleanAf.length - 1);
        }
        _backend.setProperty('audio.filter', cleanAf);
        break;
      case 'user-agent':
        _backend.setProperty('avio.user_agent', value.trim());
        break;
      case 'referrer':
        _backend.setProperty('avio.referer', value.trim());
        break;
      default:
        break;
    }
  }

  /// Updates the MDK decoder & buffer strategy at runtime (e.g. switching
  /// between `exo` 均衡 / `ijk` 老核显兼容 / `mpv` 大容量缓冲).
  void applyKernelStrategy(String kernelStrategy, {bool isLive = false}) {
    if (_disposed) return;
    _isLiveHint = isLive;
    _backend.videoDecoders = decodersForKernelStrategy(kernelStrategy);
    _applyBufferPolicy(kernelStrategy: kernelStrategy, isLive: isLive);
  }

  /// Cancels any in-flight `prepare()` call so superseding opens (e.g. episode
  /// switch while a hanging stream is still preparing) or teardown are never
  /// head-of-line blocked.
  void cancelPendingOpen() {
    _openGeneration++;
    _acceptingBackendEvents = false;
    final pending = _pendingPrepareCancel;
    _pendingPrepareCancel = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    final pendingTex = _pendingTextureWaitCancel;
    _pendingTextureWaitCancel = null;
    if (pendingTex != null && !pendingTex.isCompleted) {
      pendingTex.complete();
    }
    if (_backend is MdkExtendedNativeBackend) {
      (_backend as MdkExtendedNativeBackend).cancelPendingTextureWait();
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (_disposed) return;
    Media? media;
    Playlist nextPlaylist;
    if (playable is Media) {
      media = playable;
      nextPlaylist = Playlist(<Media>[playable], index: 0);
    } else if (playable is Playlist && playable.medias.isNotEmpty) {
      final idx = playable.index.clamp(0, playable.medias.length - 1);
      media = playable.medias[idx];
      nextPlaylist = Playlist(playable.medias, index: idx);
    } else {
      return;
    }

    final prevCancel = _pendingPrepareCancel;
    if (prevCancel != null && !prevCancel.isCompleted) {
      prevCancel.complete();
    }
    final cancel = Completer<void>();
    _pendingPrepareCancel = cancel;
    final gen = ++_openGeneration;
    _stopPositionTimer();
    _userRequestedStop = false;
    _demuxerReachedEnd = false;
    _activeVideoDecoderName = '';

    final mergedHeaders = <String, String>{};
    final lowerToKey = <String, String>{};
    void putHeader(String key, String value) {
      final k = key.trim();
      final v = value.trim();
      if (k.isEmpty || v.isEmpty) return;
      final lower = k.toLowerCase();
      final existing = lowerToKey[lower];
      if (existing != null) {
        mergedHeaders.remove(existing);
      }
      lowerToKey[lower] = k;
      mergedHeaders[k] = v;
    }

    putHeader('User-Agent', _properties['user-agent'] ?? '');
    putHeader('Referer', _properties['referrer'] ?? '');
    if (media.httpHeaders != null) {
      for (final e in media.httpHeaders!.entries) {
        putHeader(e.key, e.value);
      }
    }

    if (mergedHeaders.isNotEmpty) {
      final headerBuf = StringBuffer();
      mergedHeaders.forEach((k, v) {
        headerBuf.write('$k: $v\r\n');
      });
      _backend.setProperty('avio.headers', headerBuf.toString());
    } else {
      _backend.setProperty('avio.headers', '');
    }
    final uaKey = lowerToKey['user-agent'];
    _backend.setProperty('avio.user_agent', uaKey != null ? mergedHeaders[uaKey]! : '');
    final refKey = lowerToKey['referer'];
    _backend.setProperty('avio.referer', refKey != null ? mergedHeaders[refKey]! : '');

    final startMs = math.max(0, media.start?.inMilliseconds ?? 0);
    state = state.copyWith(
      playlist: nextPlaylist,
      playing: false,
      completed: false,
      buffering: true,
      position: Duration(milliseconds: startMs),
      duration: Duration.zero,
      buffer: Duration(milliseconds: startMs),
    );
    playlistController.add(nextPlaylist);
    bufferingController.add(true);
    completedController.add(false);
    positionController.add(Duration(milliseconds: startMs));

    _acceptingBackendEvents = false;
    _backend.state = mdk.PlaybackState.stopped;
    _backend.media = media.uri;
    _acceptingBackendEvents = true;
    final prepareFuture = _backend.prepare(position: startMs);
    unawaited(prepareFuture.then<void>((_) {}, onError: (_) {}));
    final ret = await Future.any<int?>([
      prepareFuture,
      cancel.future.then<int?>((_) => null),
    ]);
    if (identical(_pendingPrepareCancel, cancel)) {
      _pendingPrepareCancel = null;
    }
    if (_disposed || gen != _openGeneration || ret == null) return;
    if (ret < 0) {
      state = state.copyWith(playing: false, buffering: false);
      bufferingController.add(false);
      errorController.add('MDK failed to open media (code $ret)');
      return;
    }

    _syncMediaSnapshot();
    await _refreshTextureSafely(generation: gen);
    if (_disposed || gen != _openGeneration) return;

    _backend.playbackRate = state.rate.clamp(0.25, 4.0);
    _backend.volume = (state.volume / 100.0).clamp(0.0, 2.0);
    if (play) {
      _backend.state = mdk.PlaybackState.playing;
      state = state.copyWith(playing: true, buffering: false, completed: false);
      playingController.add(true);
      bufferingController.add(false);
      _startPositionTimer();
    } else {
      _backend.state = mdk.PlaybackState.paused;
      state = state.copyWith(playing: false, buffering: false);
      playingController.add(false);
      bufferingController.add(false);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _userRequestedStop = true;
    cancelPendingOpen();
    _demuxerReachedEnd = false;
    _stopPositionTimer();
    _clearActiveSubtitleLines();
    _backend.state = mdk.PlaybackState.stopped;
    state = state.copyWith(
      playing: false,
      buffering: false,
      completed: false,
      position: Duration.zero,
    );
    playingController.add(false);
    bufferingController.add(false);
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    _userRequestedStop = false;
    _backend.state = mdk.PlaybackState.playing;
    state = state.copyWith(playing: true, completed: false);
    playingController.add(true);
    _startPositionTimer();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _backend.state = mdk.PlaybackState.paused;
    _stopPositionTimer();
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration duration) async {
    if (_disposed) return;
    _demuxerReachedEnd = false;
    _clearActiveSubtitleLines();
    final targetMs = math.max(0, duration.inMilliseconds);
    final clamped = Duration(milliseconds: targetMs);
    state = state.copyWith(position: clamped, completed: false);
    positionController.add(clamped);
    await _backend.seek(
      position: targetMs,
      flags: const mdk.SeekFlag(
        mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache | mdk.SeekFlag.keyFrame,
      ),
    );
    if (!_disposed && state.playing) {
      _emitPositionAndBuffer();
    }
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    final clamped = rate.clamp(0.25, 4.0);
    _backend.playbackRate = clamped;
    state = state.copyWith(rate: clamped);
    rateController.add(clamped);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    final clamped100 = volume.clamp(0.0, 200.0);
    _backend.volume = (clamped100 / 100.0).clamp(0.0, 2.0);
    _backend.mute = clamped100 <= 0.01;
    state = state.copyWith(volume: clamped100);
    volumeController.add(clamped100);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    if (_disposed) return;
    if (track.uri) {
      _backend.setMediaForType(track.id, mdk.MediaType.audio);
    } else if (track == AudioTrack.no()) {
      _backend.activeAudioTracks = const <int>[];
    } else if (track == AudioTrack.auto()) {
      _backend.activeAudioTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeAudioTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(audio: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (_disposed) return;
    if (track.uri) {
      _backend.setMediaForType(track.id, mdk.MediaType.subtitle);
    } else if (track == SubtitleTrack.no()) {
      _backend.activeSubtitleTracks = const <int>[];
      _clearActiveSubtitleLines();
    } else if (track == SubtitleTrack.auto()) {
      _backend.activeSubtitleTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeSubtitleTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(subtitle: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setVideoTrack(VideoTrack track) async {
    if (_disposed) return;
    if (track == VideoTrack.no()) {
      _backend.activeVideoTracks = const <int>[];
    } else if (track == VideoTrack.auto()) {
      _backend.activeVideoTracks = const <int>[0];
    } else {
      final idx = int.tryParse(track.id);
      if (idx != null && idx >= 0) {
        _backend.activeVideoTracks = <int>[idx];
      }
    }
    final nextTrack = state.track.copyWith(video: track);
    state = state.copyWith(track: nextTrack);
    trackController.add(nextTrack);
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {
    if (_disposed) return;
    _backend.loop = playlistMode == PlaylistMode.single ? -1 : 0;
    state = state.copyWith(playlistMode: playlistMode);
    playlistModeController.add(playlistMode);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _userRequestedStop = true;
    cancelPendingOpen();
    _stopPositionTimer();
    await _statusSub?.cancel();
    await _stateSub?.cancel();
    await _eventSub?.cancel();
    await _subtitleSub?.cancel();
    _statusSub = null;
    _stateSub = null;
    _eventSub = null;
    _subtitleSub = null;
    try {
      _backend.state = mdk.PlaybackState.stopped;
    } catch (_) {}
    final inFlightTexture = _textureUpdateFuture;
    if (inFlightTexture != null) {
      if (_backend is MdkExtendedNativeBackend) {
        (_backend as MdkExtendedNativeBackend).cancelPendingTextureWait();
      }
      // Never delete the native `mdkPlayerAPI*` handle while an outstanding
      // `updateTexture()` still owns it; wait unconditionally for the texture
      // future to settle before invoking `_backend.disposeAsync()`.
      try {
        await inFlightTexture;
      } catch (_) {}
    }
    try {
      await _backend.disposeAsync();
    } catch (e) {
      debugPrint('MdkPlatformPlayer dispose warning: $e');
    }
    await super.dispose();
  }
}

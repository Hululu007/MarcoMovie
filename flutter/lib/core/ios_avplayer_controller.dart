// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'ohos_runtime.dart';

/// User-selectable iOS playback kernel mode.
enum IosPlaybackEngineMode {
  avPlayer(
    id: 'avplayer',
    labelZh: 'Apple 原生 (AVPlayer 低功耗)',
    shortLabel: 'AVPlayer',
  ),
  mdk(
    id: 'mdk',
    labelZh: 'MDK (Metal 4K 杜比视界)',
    shortLabel: 'MDK',
  ),
  mpv(
    id: 'mpv',
    labelZh: 'MPV 全能解码',
    shortLabel: 'MPV',
  );

  final String id;
  final String labelZh;
  final String shortLabel;

  const IosPlaybackEngineMode({
    required this.id,
    required this.labelZh,
    required this.shortLabel,
  });

  static IosPlaybackEngineMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in IosPlaybackEngineMode.values) {
      if (mode.id == normalized) return mode;
    }
    return IosPlaybackEngineMode.avPlayer;
  }
}

/// Device thermal pressure reported by iOS `ProcessInfo.processInfo.thermalState`.
enum IosThermalState {
  nominal(code: 0, wireName: 'nominal', labelZh: '正常'),
  fair(code: 1, wireName: 'fair', labelZh: '轻微升温'),
  serious(code: 2, wireName: 'serious', labelZh: '严重发热'),
  critical(code: 3, wireName: 'critical', labelZh: '临界高温');

  final int code;
  final String wireName;
  final String labelZh;

  const IosThermalState({
    required this.code,
    required this.wireName,
    required this.labelZh,
  });

  bool get isThrottled =>
      this == IosThermalState.serious || this == IosThermalState.critical;

  /// `true` once thermal pressure reaches `.fair` or higher so non-essential
  /// GPU passes (e.g. libmpv `hdr-compute-peak` & dithering) can back off early.
  bool get isElevated => code >= IosThermalState.fair.code;

  static IosThermalState fromWire(Object? raw) {
    if (raw is int) {
      for (final state in IosThermalState.values) {
        if (state.code == raw) return state;
      }
    }
    final normalized = (raw?.toString() ?? '').trim().toLowerCase();
    for (final state in IosThermalState.values) {
      if (state.wireName == normalized) return state;
    }
    return IosThermalState.nominal;
  }
}

/// Event emitted when `AVPlayer` cannot handle the stream statically or fails
/// during runtime decoding so the player can seamlessly resume on `libmpv`.
@immutable
class FallbackToMpvRequested {
  final int positionMs;
  final String reason;
  final bool isStaticPrecheck;

  const FallbackToMpvRequested({
    required this.positionMs,
    required this.reason,
    this.isStaticPrecheck = false,
  });

  @override
  String toString() =>
      'FallbackToMpvRequested(positionMs: $positionMs, reason: $reason, isStaticPrecheck: $isStaticPrecheck)';
}

/// Result of static pre-check determining whether `AVPlayer` is suitable.
@immutable
class IosAvPlayerPrecheckResult {
  final bool supported;
  final String? reason;
  final String? detectedExtension;
  final bool silentFallback;

  const IosAvPlayerPrecheckResult({
    required this.supported,
    this.reason,
    this.detectedExtension,
    this.silentFallback = false,
  });
}

/// Snapshot of device thermal state, RAM capacity, PiP, and AirPlay 2 status.
@immutable
class IosAvPlayerTelemetry {
  final IosThermalState thermalState;
  final int physicalMemoryBytes;
  final bool isPipSupported;
  final bool isPipPossible;
  final bool isPipActive;
  final double? systemVolume;
  final bool isAirPlayActive;
  final String? airPlayDeviceName;

  const IosAvPlayerTelemetry({
    required this.thermalState,
    required this.physicalMemoryBytes,
    required this.isPipSupported,
    this.isPipPossible = false,
    required this.isPipActive,
    this.systemVolume,
    required this.isAirPlayActive,
    this.airPlayDeviceName,
  });

  double get physicalMemoryGb =>
      physicalMemoryBytes / (1024.0 * 1024.0 * 1024.0);

  factory IosAvPlayerTelemetry.fromMap(Map<Object?, Object?> map) {
    final memRaw = map['physicalMemoryBytes'];
    final memBytes = memRaw is num ? memRaw.toInt() : 0;
    final devRaw = map['airPlayDeviceName']?.toString().trim() ?? '';
    final volRaw = map['systemVolume'];
    final sysVol = volRaw is num ? volRaw.toDouble().clamp(0.0, 1.0) : null;
    return IosAvPlayerTelemetry(
      thermalState: IosThermalState.fromWire(
        map['thermalState'] ?? map['thermalStateCode'],
      ),
      physicalMemoryBytes: memBytes,
      isPipSupported: map['isPipSupported'] == true,
      isPipPossible: map['isPipPossible'] == true,
      isPipActive: map['isPipActive'] == true,
      systemVolume: sysVol,
      isAirPlayActive: map['isAirPlayActive'] == true,
      airPlayDeviceName: devRaw.isEmpty ? null : devRaw,
    );
  }
}

/// Three-state classification of an `AVMediaSelectionGroup` subtitle track.
enum IosAvSubtitleFormat {
  text,
  bitmap,
  unknown;

  static IosAvSubtitleFormat fromWire(
    Object? raw, {
    required bool isBitmap,
    required bool? isTextExtractable,
  }) {
    final normalized = (raw?.toString() ?? '').trim().toLowerCase();
    if (normalized == 'text') return IosAvSubtitleFormat.text;
    if (normalized == 'bitmap' || normalized == 'graphical') {
      return IosAvSubtitleFormat.bitmap;
    }
    if (normalized == 'unknown') return IosAvSubtitleFormat.unknown;
    if (isBitmap || isTextExtractable == false) {
      return IosAvSubtitleFormat.bitmap;
    }
    if (isTextExtractable == true) {
      return IosAvSubtitleFormat.text;
    }
    return IosAvSubtitleFormat.unknown;
  }
}

/// Audio or subtitle track reported by `AVMediaSelectionGroup`.
@immutable
class IosAvPlayerTrack {
  final String id;
  final String title;
  final String language;
  final bool selected;
  final bool isBitmap;
  final bool? isTextExtractable;
  final IosAvSubtitleFormat subtitleFormat;

  const IosAvPlayerTrack({
    required this.id,
    required this.title,
    this.language = '',
    this.selected = false,
    this.isBitmap = false,
    this.isTextExtractable,
    IosAvSubtitleFormat? subtitleFormat,
  }) : subtitleFormat = subtitleFormat ??
            (isBitmap || isTextExtractable == false
                ? IosAvSubtitleFormat.bitmap
                : (isTextExtractable == true
                    ? IosAvSubtitleFormat.text
                    : IosAvSubtitleFormat.unknown));

  factory IosAvPlayerTrack.fromMap(Map<Object?, Object?> map) {
    final isBitmap = map['isBitmap'] == true;
    final rawExtractable = map['isTextExtractable'] is bool
        ? map['isTextExtractable'] as bool
        : null;
    final format = IosAvSubtitleFormat.fromWire(
      map['subtitleFormat'],
      isBitmap: isBitmap,
      isTextExtractable: rawExtractable,
    );
    return IosAvPlayerTrack(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      language: (map['language'] ?? '').toString(),
      selected: map['selected'] == true,
      isBitmap: isBitmap || format == IosAvSubtitleFormat.bitmap,
      isTextExtractable: rawExtractable ??
          switch (format) {
            IosAvSubtitleFormat.text => true,
            IosAvSubtitleFormat.bitmap => false,
            IosAvSubtitleFormat.unknown => null,
          },
      subtitleFormat: format,
    );
  }
}

/// Controller bridging `MarcoAvPlayerEngine.swift` (`AVQueuePlayer` +
/// `AVPlayerLayer` + `AVPictureInPictureController` + AirPlay 2 + thermal
/// telemetry) to Flutter.
class IosAvPlayerController extends ChangeNotifier {
  static const String viewType = 'marco_movie/ios_avplayer_view';
  static const MethodChannel defaultChannel = MethodChannel(
    'marco_movie/ios_avplayer',
  );
  static const EventChannel defaultEventChannel = EventChannel(
    'marco_movie/ios_avplayer_events',
  );

  static const Set<String> incompatibleUrlSchemes = <String>{
    'rtsp',
    'rtsps',
    'rtmp',
    'rtmps',
    'rtp',
    'udp',
    'mms',
    'mmsh',
    'mmst',
    'igmp',
  };

  static const Set<String> incompatibleContainerExtensions = <String>{
    '.mkv',
    '.flv',
    '.avi',
    '.wmv',
    '.rmvb',
    '.rm',
    '.webm',
    '.vob',
    '.ogv',
    '.divx',
    '.asf',
    '.3gp',
    '.smil',
    '.ts',
    '.m2ts',
    '.mts',
    '.mpeg',
    '.mpg',
    '.mxf',
  };

  static const Set<String> avPlayerNativeExtensions = <String>{
    '.m3u8',
    '.mp4',
    '.mov',
    '.m4v',
    '.mp3',
    '.aac',
    '.m4a',
  };

  static const Set<String> incompatibleSubtitleExtensions = <String>{
    '.ass',
    '.ssa',
    '.sup',
    '.pgs',
    '.idx',
    '.sub',
  };

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final TargetPlatform? platformOverride;
  final bool? isOhosOverride;
  final bool? isWebOverride;

  final StreamController<FallbackToMpvRequested> _fallbackCtrl =
      StreamController<FallbackToMpvRequested>.broadcast();
  final StreamController<IosThermalState> _thermalCtrl =
      StreamController<IosThermalState>.broadcast();
  final StreamController<bool> _pipCtrl = StreamController<bool>.broadcast();
  final StreamController<String> _pipErrorCtrl =
      StreamController<String>.broadcast();
  final StreamController<void> _pipRestoreCtrl =
      StreamController<void>.broadcast();
  final StreamController<bool> _airPlayCtrl =
      StreamController<bool>.broadcast();
  final StreamController<double> _systemVolumeCtrl =
      StreamController<double>.broadcast();
  final StreamController<({List<String> lines, bool hasNativeSamples})>
      _subtitleCueCtrl =
      StreamController<({List<String> lines, bool hasNativeSamples})>.broadcast();

  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;
  bool _disposed = false;
  bool _fallbackEmittedForCurrentItem = false;

  bool _playing = false;
  bool? _requestedPlaying;
  static int _nextMediaId = 0;
  int? _mediaId;
  bool _buffering = false;
  bool _ready = false;
  bool _completed = false;
  bool _hasError = false;
  Duration _position = Duration.zero;
  Duration? _nativePositionSample;
  int _nativePositionSampleSeq = 0;
  int? _nativePositionSampleEventSeq;
  int? _nativePositionSampleMediaId;
  Duration? _confirmedSeekPosition;
  int? _confirmedSeekMediaId;
  int _confirmedSeekSampleSeq = -1;
  int? _confirmedSeekEventSeq;
  int _confirmedSeekGen = 0;
  int _seekGeneration = 0;
  int _latestSeekDispatchedSampleSeq = -1;
  int? _seekBurstOriginPosMs;
  int? _pendingCompletedMediaId;
  int? _pendingCompletedEventSeq;
  int? _completionSuppressMediaId;
  int? _completionSuppressEventSeq;
  final Set<int> _inFlightSeekGens = <int>{};
  final Map<int, ({int targetMs, int sampleSeqAtDispatch})> _burstSeekTargets =
      <int, ({int targetMs, int sampleSeqAtDispatch})>{};
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  double _rate = 1.0;
  double _volume = 1.0;
  double _systemVolume = 0.5;
  bool _hasSystemVolume = false;
  int _videoWidth = 0;
  int _videoHeight = 0;
  bool _isHdr = false;
  bool _isPipSupported = false;
  bool _isPipPossible = false;
  bool _isPipStarting = false;
  bool _isPipActive = false;
  String? _lastPipError;
  bool _autoPipEnabled = true;
  bool _isAirPlayActive = false;
  String? _airPlayDeviceName;
  IosThermalState _thermalState = IosThermalState.nominal;
  int _physicalMemoryBytes = 0;
  List<IosAvPlayerTrack> _audioTracks = const <IosAvPlayerTrack>[];
  List<IosAvPlayerTrack> _subtitleTracks = const <IosAvPlayerTrack>[];
  List<String> _activeSubtitleLines = const <String>[];
  bool _currentSubtitleHasNonTextSamples = false;
  bool _suppressNativeSubtitleRendering = false;
  bool _suppressNativeSubtitleAllowNonText = false;
  bool _suppressNativeSubtitleSynced = false;
  String? _lastError;

  IosAvPlayerController({
    MethodChannel? channelOverride,
    EventChannel? eventChannelOverride,
    this.platformOverride,
    this.isOhosOverride,
    this.isWebOverride,
  })  : _channel = channelOverride ?? defaultChannel,
        _eventChannel = eventChannelOverride ?? defaultEventChannel;

  bool get isSupportedPlatform {
    if (isWebOverride ?? kIsWeb) return false;
    if (isOhosOverride ?? OhosRuntime.isOhos) return false;
    final platform = platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.iOS;
  }

  bool get initialized => _initialized;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get ready => _ready;
  bool get completed => _completed;
  bool get hasError => _hasError;
  Duration get position => _position;
  /// Latest playback position explicitly reported by native AVPlayer
  /// (`ready` / `playbackState` / `progress` / `completed`), never mutated
  /// optimistically by `open()` or `seek()`.
  Duration? get nativePositionSample => _nativePositionSample;
  int get nativePositionSampleSeq => _nativePositionSampleSeq;
  int? get nativePositionSampleMediaId => _nativePositionSampleMediaId;
  Duration get duration => _duration;
  Duration get bufferedPosition => _bufferedPosition;
  double get rate => _rate;
  double get volume => _volume;
  double get systemVolume => _systemVolume;
  bool get hasSystemVolume => _hasSystemVolume;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;
  bool get isHdr => _isHdr;
  int? get currentMediaId => _mediaId;
  bool get _hasActivePendingSeek =>
      _inFlightSeekGens.any((g) => g > _confirmedSeekGen);
  bool get _hasLatestPendingSeek =>
      _inFlightSeekGens.contains(_seekGeneration);
  bool get hasInFlightSeek => _hasLatestPendingSeek;

  /// Single source of truth for the current media item's latest confirmed
  /// playback position (resolving native clock samples vs accepted seek
  /// landings in strict sequence order).
  Duration? get confirmedPosition {
    final mediaId = _mediaId;
    final hasMatchingNative =
        _nativePositionSample != null &&
        _nativePositionSampleMediaId == mediaId;
    final hasMatchingConfirmedSeek =
        _confirmedSeekPosition != null &&
        _confirmedSeekMediaId == mediaId;
    if (hasMatchingNative) {
      if (!hasMatchingConfirmedSeek) {
        return _nativePositionSample;
      }
      if (_nativePositionSampleEventSeq != null &&
          _confirmedSeekEventSeq != null) {
        return _nativePositionSampleEventSeq! > _confirmedSeekEventSeq!
            ? _nativePositionSample
            : _confirmedSeekPosition;
      }
      if (_nativePositionSampleSeq > _confirmedSeekSampleSeq) {
        return _nativePositionSample;
      }
      return _confirmedSeekPosition;
    }
    return hasMatchingConfirmedSeek ? _confirmedSeekPosition : null;
  }
  bool get isPipSupported => _isPipSupported;
  bool get isPipPossible => _isPipPossible;
  bool get isPipStarting => _isPipStarting;
  bool get isPipActive => _isPipActive;
  String? get lastPipError => _lastPipError;
  bool get autoPipEnabled => _autoPipEnabled;
  bool get isAirPlayActive => _isAirPlayActive;
  String? get airPlayDeviceName => _airPlayDeviceName;
  IosThermalState get thermalState => _thermalState;
  int get physicalMemoryBytes => _physicalMemoryBytes;
  List<IosAvPlayerTrack> get audioTracks => _audioTracks;
  List<IosAvPlayerTrack> get subtitleTracks => _subtitleTracks;
  List<String> get activeSubtitleLines => _activeSubtitleLines;
  bool get currentSubtitleHasNonTextSamples => _currentSubtitleHasNonTextSamples;
  bool get suppressNativeSubtitleRendering => _suppressNativeSubtitleRendering;
  String? get lastError => _lastError;

  Stream<FallbackToMpvRequested> get onFallbackToMpvRequested =>
      _fallbackCtrl.stream;
  Stream<IosThermalState> get onThermalStateChanged => _thermalCtrl.stream;
  Stream<bool> get onPipStateChanged => _pipCtrl.stream;
  Stream<String> get onPipError => _pipErrorCtrl.stream;
  Stream<void> get onPipRestoreForeground => _pipRestoreCtrl.stream;
  Stream<bool> get onAirPlayStateChanged => _airPlayCtrl.stream;
  Stream<double> get onSystemVolumeChanged => _systemVolumeCtrl.stream;
  Stream<({List<String> lines, bool hasNativeSamples})>
      get onSubtitleCueChanged => _subtitleCueCtrl.stream;

  /// Static pre-check before launching `AVPlayer`.
  ///
  /// Returns `supported: false` when external subtitles contain `.ass`/`.ssa`
  /// (or PGS/VobSub) or when the container format (e.g. `.mkv`, `.flv`,
  /// `.avi`, `.webm`) requires `libmpv` decoding.
  static IosAvPlayerPrecheckResult checkUrlCompatibility(
    String url, {
    String? episodeName,
    String? lineName,
    List<String> externalSubtitles = const <String>[],
  }) {
    for (final sub in externalSubtitles) {
      final subExt = _extractExtension(sub);
      if (subExt != null && incompatibleSubtitleExtensions.contains(subExt)) {
        return IosAvPlayerPrecheckResult(
          supported: false,
          reason: '外挂特效/图形字幕 ($subExt) 需要 libmpv 渲染',
          detectedExtension: subExt,
        );
      }
    }

    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) {
      return const IosAvPlayerPrecheckResult(
        supported: false,
        reason: '播放地址为空',
      );
    }

    final uri = Uri.tryParse(cleanUrl);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme.isNotEmpty && incompatibleUrlSchemes.contains(scheme)) {
      return IosAvPlayerPrecheckResult(
        supported: false,
        reason: '流媒体协议 $scheme:// 使用 MPV 内核解码',
        detectedExtension: '$scheme://',
        silentFallback: true,
      );
    }
    if (scheme.isNotEmpty &&
        scheme != 'http' &&
        scheme != 'https' &&
        scheme != 'file') {
      return IosAvPlayerPrecheckResult(
        supported: false,
        reason: '协议 $scheme:// 使用 MPV 内核解码',
        detectedExtension: '$scheme://',
        silentFallback: true,
      );
    }

    final urlExt = _extractExtension(cleanUrl);
    if (urlExt != null) {
      if (incompatibleContainerExtensions.contains(urlExt)) {
        return IosAvPlayerPrecheckResult(
          supported: false,
          reason: '容器格式 $urlExt 不受系统 AVPlayer 支持，已自动切换 MPV',
          detectedExtension: urlExt,
          silentFallback: urlExt == '.smil' || urlExt == '.ts',
        );
      }
      if (avPlayerNativeExtensions.contains(urlExt)) {
        final lower = cleanUrl.toLowerCase();
        if (urlExt == '.m3u8' &&
            !lower.startsWith('http://') &&
            !lower.startsWith('https://')) {
          return IosAvPlayerPrecheckResult(
            supported: false,
            reason: '本地离线 HLS 播放列表将自动切换至 MPV 播放',
            detectedExtension: urlExt,
          );
        }
        return IosAvPlayerPrecheckResult(
          supported: true,
          detectedExtension: urlExt,
        );
      }
    }

    // Check query parameters (e.g. `?format=mkv` or `filename=video.flv`) when
    // the URL path has no explicit media extension.
    if (uri != null) {
      for (final val in uri.queryParameters.values) {
        final trimmedVal = val.trim().toLowerCase();
        final qExt = _extractExtension(trimmedVal) ??
            (RegExp(r'^[a-z0-9]{2,5}$').hasMatch(trimmedVal)
                ? '.$trimmedVal'
                : null);
        if (qExt != null && incompatibleContainerExtensions.contains(qExt)) {
          return IosAvPlayerPrecheckResult(
            supported: false,
            reason: '流格式参数 $qExt 不受系统 AVPlayer 支持，已自动切换 MPV',
            detectedExtension: qExt,
          );
        }
      }
    }

    // Fall back to episode/line hints only when URL itself had no extension.
    if (urlExt == null) {
      for (final hint in <String?>[episodeName, lineName]) {
        final hintExt = _extractExtension(hint ?? '');
        if (hintExt != null &&
            incompatibleContainerExtensions.contains(hintExt)) {
          return IosAvPlayerPrecheckResult(
            supported: false,
            reason: '片源标识 $hintExt 建议使用 libmpv 解码',
            detectedExtension: hintExt,
          );
        }
      }
    }

    return IosAvPlayerPrecheckResult(
      supported: true,
      detectedExtension: urlExt,
    );
  }

  static String? _extractExtension(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    final path = (parsed?.path.isNotEmpty == true ? parsed!.path : trimmed)
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
    final match = RegExp(r'(\.[a-z0-9]{2,5})$').firstMatch(path);
    return match?.group(1);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCallback);

    if (isSupportedPlatform) {
      try {
        _eventSub = _eventChannel.receiveBroadcastStream().listen(
          (dynamic event) {
            if (event is Map) {
              handleNativeEvent(Map<Object?, Object?>.from(event));
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
      await refreshTelemetry();
    }
  }

  Future<dynamic> _handleMethodCallback(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'onFallbackToMpv' && call.arguments is Map) {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      handleNativeEvent(<Object?, Object?>{
        'type': 'fallbackToMpv',
        ...args,
      });
    } else if (call.method == 'onPipRestoreForeground') {
      handleNativeEvent(const <Object?, Object?>{'type': 'pipRestoreForeground'});
    } else if (call.method == 'onEvent' && call.arguments is Map) {
      handleNativeEvent(Map<Object?, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  /// Processes a native event map (from EventChannel, MethodChannel, or tests).
  @visibleForTesting
  void handleNativeEvent(Map<Object?, Object?> event) {
    if (_disposed) return;
    final mediaId = event['mediaId'];
    if (mediaId != null && mediaId != _mediaId) return;
    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'telemetry':
        _applyTelemetry(IosAvPlayerTelemetry.fromMap(event));
        _notify();
        break;
      case 'thermalStateChanged':
        final nextThermal = IosThermalState.fromWire(
          event['thermalState'] ?? event['thermalStateCode'],
        );
        if (nextThermal != _thermalState) {
          _thermalState = nextThermal;
          if (!_thermalCtrl.isClosed) _thermalCtrl.add(nextThermal);
          _notify();
        }
        break;
      case 'pipStateChanged':
        final phase = event['phase']?.toString() ?? '';
        // Only treat PiP as active once native confirms didStart (or active
        // state outside transient willStart).
        final active = phase == 'willStart' ? false : (event['active'] == true);
        final nextSupported = event.containsKey('supported')
            ? event['supported'] == true
            : _isPipSupported;
        final nextPossible = event.containsKey('possible')
            ? event['possible'] == true
            : _isPipPossible;
        final nextStarting = switch (phase) {
          'willStart' => true,
          'didStart' ||
          'failed' ||
          'cancelled' ||
          'willStop' ||
          'didStop' ||
          'notReady' =>
            false,
          _ => active ? false : _isPipStarting,
        };
        final isFailed = phase == 'failed';
        final failureMessage = isFailed
            ? ((event['error']?.toString().trim().isNotEmpty ?? false)
                ? event['error']!.toString().trim()
                : '无法开启画中画')
            : null;
        final nextPipError = isFailed
            ? failureMessage
            : (active ? null : _lastPipError);
        final activeChanged = active != _isPipActive;
        final changed = activeChanged ||
            nextSupported != _isPipSupported ||
            nextPossible != _isPipPossible ||
            nextStarting != _isPipStarting ||
            nextPipError != _lastPipError ||
            isFailed;
        _isPipSupported = nextSupported;
        _isPipPossible = nextPossible;
        _isPipStarting = nextStarting;
        _isPipActive = active;
        _lastPipError = nextPipError;
        if (activeChanged && !_pipCtrl.isClosed) {
          _pipCtrl.add(active);
        }
        if (isFailed && failureMessage != null && !_pipErrorCtrl.isClosed) {
          _pipErrorCtrl.add(failureMessage);
        }
        if (changed) {
          _notify();
        }
        break;
      case 'systemVolumeChanged':
        final rawVol = event['volume'];
        if (rawVol is num) {
          final clamped = rawVol.toDouble().clamp(0.0, 1.0);
          final changed = !_hasSystemVolume || (clamped - _systemVolume).abs() >= 0.001;
          _systemVolume = clamped;
          _hasSystemVolume = true;
          if (changed) {
            if (!_systemVolumeCtrl.isClosed) _systemVolumeCtrl.add(clamped);
            _notify();
          }
        }
        break;
      case 'pipRestoreForeground':
        if (!_pipRestoreCtrl.isClosed) _pipRestoreCtrl.add(null);
        break;
      case 'airPlayStateChanged':
        final active = event['isAirPlayActive'] == true;
        final dev = event['deviceName']?.toString().trim() ?? '';
        final nextName = dev.isEmpty ? null : dev;
        final changed =
            active != _isAirPlayActive || nextName != _airPlayDeviceName;
        _isAirPlayActive = active;
        _airPlayDeviceName = nextName;
        if (changed) {
          if (!_airPlayCtrl.isClosed) _airPlayCtrl.add(active);
          _notify();
        }
        break;
      case 'ready':
        _ready = true;
        _buffering = false;
        _hasError = false;
        _lastError = null;
        _updateMetricsFromMap(event, recordClockSample: true);
        if (event['audioTracks'] is List) {
          _audioTracks = _parseTrackList(event['audioTracks'] as List);
        }
        if (event['subtitleTracks'] is List) {
          _subtitleTracks = _parseTrackList(event['subtitleTracks'] as List);
        }
        _notify();
        break;
      case 'subtitleCue':
        final rawLines = event['lines'];
        final lines = rawLines is List
            ? rawLines
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList(growable: false)
            : const <String>[];
        final hasNativeSamples = event['hasNativeSamples'] == true;
        _activeSubtitleLines = lines;
        _currentSubtitleHasNonTextSamples = hasNativeSamples && lines.isEmpty;
        if (!_subtitleCueCtrl.isClosed) {
          _subtitleCueCtrl.add((
            lines: lines,
            hasNativeSamples: hasNativeSamples,
          ));
        }
        _notify();
        break;
      case 'subtitleTracksChanged':
        if (event['subtitleTracks'] is List) {
          _subtitleTracks = _parseTrackList(event['subtitleTracks'] as List);
          _notify();
        }
        break;
      case 'videoSize':
        _updateMetricsFromMap(event);
        _notify();
        break;
      case 'playbackState':
        _playing = event['playing'] == true;
        if (_playing == _requestedPlaying) _requestedPlaying = null;
        _buffering = event['buffering'] == true;
        if (event['rate'] is num) {
          final r = (event['rate'] as num).toDouble();
          if (r > 0) _rate = r;
        }
        _updateMetricsFromMap(event, recordClockSample: true);
        _notify();
        break;
      case 'progress':
        _playing = event['playing'] == true;
        if (_playing == _requestedPlaying) _requestedPlaying = null;
        _updateMetricsFromMap(event, recordClockSample: true);
        _notify();
        break;
      case 'buffering':
        final nextBuf = event['buffering'] == true;
        if (nextBuf != _buffering) {
          _buffering = nextBuf;
          _notify();
        }
        break;
      case 'completed':
        final incomingCompletedSeq = event['eventSeq'] is num
            ? (event['eventSeq'] as num).toInt()
            : null;
        final isStaleAfterSeekAwayFromEnd =
            incomingCompletedSeq != null &&
            _completionSuppressMediaId == _mediaId &&
            _completionSuppressEventSeq != null &&
            incomingCompletedSeq <= _completionSuppressEventSeq!;
        if (isStaleAfterSeekAwayFromEnd) {
          break;
        }
        _updateMetricsFromMap(event, recordClockSample: true);
        if (_hasActivePendingSeek) {
          // A still-unsettled seek on the same media item may supersede this
          // end-of-item event (e.g. scrubbing back from 99.75s -> 50s).
          // Defer completion side effects until active in-flight seek(s) settle.
          if (_pendingCompletedMediaId != _mediaId ||
              _pendingCompletedEventSeq == null ||
              incomingCompletedSeq == null ||
              incomingCompletedSeq >= _pendingCompletedEventSeq!) {
            _pendingCompletedMediaId = _mediaId;
            _pendingCompletedEventSeq =
                incomingCompletedSeq ?? _pendingCompletedEventSeq;
          }
          _notify();
          break;
        }
        _pendingCompletedMediaId = null;
        _pendingCompletedEventSeq = null;
        _playing = false;
        _requestedPlaying = null;
        _completed = true;
        _notify();
        break;
      case 'fallbackToMpv':
        final posMs = (event['positionMs'] is num)
            ? (event['positionMs'] as num).toInt()
            : _position.inMilliseconds;
        final reason = event['reason']?.toString() ?? 'AVPlayer playback failed';
        _playing = false;
        _requestedPlaying = null;
        _buffering = false;
        _hasError = true;
        _lastError = reason;
        if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
          _fallbackEmittedForCurrentItem = true;
          _fallbackCtrl.add(
            FallbackToMpvRequested(
              positionMs: posMs,
              reason: reason,
              isStaticPrecheck: false,
            ),
          );
        }
        _notify();
        break;
    }
  }

  List<IosAvPlayerTrack> _parseTrackList(List<dynamic> raw) {
    final out = <IosAvPlayerTrack>[];
    for (final entry in raw) {
      if (entry is Map) {
        out.add(IosAvPlayerTrack.fromMap(Map<Object?, Object?>.from(entry)));
      }
    }
    return out;
  }

  void _updateMetricsFromMap(
    Map<Object?, Object?> map, {
    bool recordClockSample = false,
  }) {
    if (map['positionMs'] is num) {
      final reported =
          Duration(milliseconds: (map['positionMs'] as num).toInt());
      final incomingEventSeq =
          map['eventSeq'] is num ? (map['eventSeq'] as num).toInt() : null;
      final isStaleNativeSample =
          recordClockSample &&
          incomingEventSeq != null &&
          _nativePositionSampleMediaId == _mediaId &&
          _nativePositionSampleEventSeq != null &&
          incomingEventSeq <= _nativePositionSampleEventSeq!;
      final isOlderThanConfirmedSeek =
          recordClockSample &&
          incomingEventSeq != null &&
          _confirmedSeekMediaId == _mediaId &&
          _confirmedSeekEventSeq != null &&
          incomingEventSeq <= _confirmedSeekEventSeq!;
      if (!isStaleNativeSample && !isOlderThanConfirmedSeek) {
        // Freeze displayed position ONLY while the latest user seek target is
        // still pending; once the latest target settles (even if an older
        // superseded seek is still in flight), let real clock progression
        // drive the scrubber and relative ±15s jumps.
        if (!_hasLatestPendingSeek) {
          _position = reported;
        }
        if (recordClockSample) {
          _nativePositionSample = reported;
          _nativePositionSampleSeq++;
          _nativePositionSampleMediaId = _mediaId;
          _nativePositionSampleEventSeq = incomingEventSeq;
        }
      }
    }
    if (map['durationMs'] is num) {
      _duration = Duration(milliseconds: (map['durationMs'] as num).toInt());
    }
    if (map['bufferedMs'] is num) {
      _bufferedPosition =
          Duration(milliseconds: (map['bufferedMs'] as num).toInt());
    }
    if (map['width'] is num) {
      _videoWidth = (map['width'] as num).toInt();
    }
    if (map['height'] is num) {
      _videoHeight = (map['height'] as num).toInt();
    }
    if (map.containsKey('isHdr')) {
      _isHdr = map['isHdr'] == true;
    }
  }

  void _applyTelemetry(IosAvPlayerTelemetry t) {
    _thermalState = t.thermalState;
    if (t.physicalMemoryBytes > 0) {
      _physicalMemoryBytes = t.physicalMemoryBytes;
    }
    _isPipSupported = t.isPipSupported;
    _isPipPossible = t.isPipPossible;
    _isPipActive = t.isPipActive;
    if (t.systemVolume != null) {
      _systemVolume = t.systemVolume!;
      _hasSystemVolume = true;
    }
    _isAirPlayActive = t.isAirPlayActive;
    _airPlayDeviceName = t.airPlayDeviceName;
  }

  /// Opens [url] with custom HTTP [headers] on `AVPlayer`.
  ///
  /// Performs static compatibility pre-check first; if incompatible (`.mkv`,
  /// `.flv`, `.avi`, `.ass`/`.ssa` subtitles), immediately emits
  /// [FallbackToMpvRequested] and returns `false`.
  Future<bool> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
    Duration startPosition = Duration.zero,
    bool autoPlay = true,
    double preferredForwardBufferDuration = 24.0,
    String? episodeName,
    String? lineName,
    List<String> externalSubtitles = const <String>[],
    bool suppressNativeSubtitleRendering = false,
    bool suppressNativeSubtitleAllowNonText = false,
  }) async {
    if (_disposed) return false;
    final mediaId = ++_nextMediaId;
    _mediaId = mediaId;
    _requestedPlaying = null;
    _playing = false;
    _buffering = false;
    _duration = Duration.zero;
    _nativePositionSample = null;
    _nativePositionSampleEventSeq = null;
    _nativePositionSampleMediaId = mediaId;
    _confirmedSeekPosition = null;
    _confirmedSeekMediaId = null;
    _confirmedSeekSampleSeq = -1;
    _confirmedSeekEventSeq = null;
    _seekGeneration++;
    _confirmedSeekGen = _seekGeneration;
    _latestSeekDispatchedSampleSeq = -1;
    _seekBurstOriginPosMs = null;
    _pendingCompletedMediaId = null;
    _pendingCompletedEventSeq = null;
    _completionSuppressMediaId = null;
    _completionSuppressEventSeq = null;
    _inFlightSeekGens.clear();
    _burstSeekTargets.clear();
    await initialize();
    if (_disposed || _mediaId != mediaId) return false;
    _fallbackEmittedForCurrentItem = false;

    final precheck = checkUrlCompatibility(
      url,
      episodeName: episodeName,
      lineName: lineName,
      externalSubtitles: externalSubtitles,
    );
    if (!precheck.supported) {
      final reason = precheck.reason ?? 'AVPlayer 不支持当前格式';
      _lastError = reason;
      if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
        _fallbackEmittedForCurrentItem = true;
        _fallbackCtrl.add(
          FallbackToMpvRequested(
            positionMs: startPosition.inMilliseconds,
            reason: reason,
            isStaticPrecheck: true,
          ),
        );
      }
      _notify();
      return false;
    }

    if (!isSupportedPlatform) return false;
    _ready = false;
    _completed = false;
    _hasError = false;
    _lastError = null;
    _activeSubtitleLines = const <String>[];
    _currentSubtitleHasNonTextSamples = false;
    _suppressNativeSubtitleRendering = suppressNativeSubtitleRendering;
    _suppressNativeSubtitleAllowNonText =
        suppressNativeSubtitleRendering && suppressNativeSubtitleAllowNonText;
    _suppressNativeSubtitleSynced = true;
    _position = startPosition;
    _notify();

    try {
      final ok = await _channel.invokeMethod<bool>(
        'open',
        <String, dynamic>{
          'mediaId': mediaId,
          'url': url,
          'headers': headers,
          'startPositionMs': startPosition.inMilliseconds,
          'autoPlay': autoPlay,
          'preferredForwardBufferDuration': preferredForwardBufferDuration,
          'suppressNativeSubtitleRendering': suppressNativeSubtitleRendering,
          'suppressNativeSubtitleAllowNonText':
              suppressNativeSubtitleRendering && suppressNativeSubtitleAllowNonText,
        },
      );
      return _mediaId == mediaId && ok == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      if (_disposed || _mediaId != mediaId) return false;
      _hasError = true;
      _lastError = e.toString();
      if (!_fallbackEmittedForCurrentItem && !_fallbackCtrl.isClosed) {
        _fallbackEmittedForCurrentItem = true;
        _fallbackCtrl.add(
          FallbackToMpvRequested(
            positionMs: startPosition.inMilliseconds,
            reason: e.toString(),
            isStaticPrecheck: false,
          ),
        );
      }
      _notify();
      return false;
    }
  }

  Future<void> _requestPlayback(bool playing) async {
    if (!isSupportedPlatform || _disposed) return;
    final mediaId = _mediaId;
    _requestedPlaying = playing;
    try {
      await _channel.invokeMethod<void>(playing ? 'play' : 'pause');
    } catch (_) {
      if (mediaId == _mediaId && _requestedPlaying == playing) {
        _requestedPlaying = null;
      }
    }
  }

  Future<void> play() => _requestPlayback(true);
  Future<void> pause() => _requestPlayback(false);
  Future<void> playOrPause() => (_requestedPlaying ?? _playing) ? pause() : play();

  Future<bool> seek(Duration target) async {
    if (!isSupportedPlatform || _disposed) return false;
    final clampedMs = target.inMilliseconds < 0 ? 0 : target.inMilliseconds;
    final mediaId = _mediaId;
    final seekGen = ++_seekGeneration;
    final sampleSeqAtDispatch = _nativePositionSampleSeq;
    final preSeekPos = confirmedPosition ?? _nativePositionSample;
    if (!_hasActivePendingSeek) {
      _seekBurstOriginPosMs = preSeekPos?.inMilliseconds;
      _burstSeekTargets.removeWhere((g, _) => g <= _confirmedSeekGen);
    }
    final burstOriginMs = _seekBurstOriginPosMs ?? preSeekPos?.inMilliseconds;
    _latestSeekDispatchedSampleSeq = sampleSeqAtDispatch;
    _inFlightSeekGens.add(seekGen);
    _burstSeekTargets[seekGen] = (
      targetMs: clampedMs,
      sampleSeqAtDispatch: sampleSeqAtDispatch,
    );
    final optimisticPos = Duration(milliseconds: clampedMs);
    _position = optimisticPos;
    _clearActiveSubtitleCue();
    _notify();

    void finishSeekAndReconcile() {
      _inFlightSeekGens.remove(seekGen);
      if (_inFlightSeekGens.isEmpty) {
        _seekBurstOriginPosMs = null;
        _burstSeekTargets.clear();
      }
      if (_disposed || _mediaId != mediaId) return;
      final hasNewerInFlight = _inFlightSeekGens.any((g) => g > seekGen);
      if (hasNewerInFlight) return;
      var changed = false;
      final resolved = confirmedPosition ?? Duration.zero;
      if (_position != resolved) {
        _position = resolved;
        changed = true;
      }
      if (!_hasActivePendingSeek && _pendingCompletedMediaId == mediaId) {
        final pendingSeq = _pendingCompletedEventSeq;
        final supersededBySeekAwayFromEnd =
            pendingSeq != null &&
            _completionSuppressMediaId == mediaId &&
            _completionSuppressEventSeq != null &&
            _completionSuppressEventSeq! >= pendingSeq;
        _pendingCompletedMediaId = null;
        _pendingCompletedEventSeq = null;
        if (!supersededBySeekAwayFromEnd) {
          _playing = false;
          _requestedPlaying = null;
          if (!_completed) {
            _completed = true;
            changed = true;
          }
        }
      }
      if (changed) {
        _notify();
      }
    }

    try {
      final rawReply = await _channel.invokeMethod<dynamic>('seek', clampedMs);
      final bool replyOk;
      final int? replyEventSeq;
      final int? replyPositionMs;
      if (rawReply is Map) {
        replyOk = rawReply['finished'] == true;
        replyEventSeq = rawReply['eventSeq'] is num
            ? (rawReply['eventSeq'] as num).toInt()
            : null;
        replyPositionMs = rawReply['positionMs'] is num
            ? (rawReply['positionMs'] as num).toInt()
            : null;
      } else {
        replyOk = rawReply != false;
        replyEventSeq = null;
        replyPositionMs = null;
      }
      final nativeAccepted = replyOk && !_disposed && _mediaId == mediaId;
      final isLatest = _seekGeneration == seekGen;
      if (nativeAccepted) {
        final hasMatchingNative =
            _nativePositionSample != null &&
            _nativePositionSampleMediaId == mediaId;
        final hasNewerSample =
            hasMatchingNative && _nativePositionSampleSeq > sampleSeqAtDispatch;
        var sampleSupersedesSeek = false;
        if (replyEventSeq != null &&
            hasMatchingNative &&
            _nativePositionSampleEventSeq != null) {
          // Exact native monotonic ordering when `MarcoAvPlayerEngine` stamps
          // both clock events and seek completions with `eventSeq`.
          sampleSupersedesSeek =
              _nativePositionSampleEventSeq! > replyEventSeq;
        } else if (hasNewerSample && !isLatest) {
          // Legacy `bool`-only bridge fallback: distinguish pre-seek ticks
          // still continuing along the pre-burst timeline (both forward and
          // backward seeks while playing or paused) from genuine post-seek
          // landing / clock samples. A sample that already arrived before a
          // later request was dispatched can never be attributed to that later
          // request.
          final sampleMs = _nativePositionSample!.inMilliseconds;
          final maxOldTimelineDriftMs =
              (2500 * _rate.clamp(1.0, 4.0)).round();
          final onOldPreSeekTimeline =
              burstOriginMs != null &&
              sampleMs >= burstOriginMs - 250 &&
              sampleMs <= burstOriginMs + maxOldTimelineDriftMs;

          bool nearTarget(int t) {
            final tol = math.min(1500, (t * 0.25).round());
            return sampleMs >= t - tol &&
                sampleMs <= t + maxOldTimelineDriftMs;
          }

          final landedAtNewerSeek = _burstSeekTargets.entries.any((e) {
            if (e.key <= seekGen) return false;
            if (_nativePositionSampleSeq <= e.value.sampleSeqAtDispatch) {
              return false;
            }
            if (!nearTarget(e.value.targetMs)) return false;
            if (!onOldPreSeekTimeline) return true;
            return (sampleMs - e.value.targetMs).abs() <
                (sampleMs - burstOriginMs).abs();
          });
          final landedAtThisSeek =
              clampedMs > 0 &&
              nearTarget(clampedMs) &&
              sampleMs >= clampedMs &&
              !onOldPreSeekTimeline;
          final arrivedAfterLatestSeekDispatch =
              _nativePositionSampleSeq > _latestSeekDispatchedSampleSeq;

          if (landedAtNewerSeek ||
              landedAtThisSeek ||
              (!onOldPreSeekTimeline && arrivedAfterLatestSeekDispatch)) {
            sampleSupersedesSeek = true;
          }
        }
        final landedMs =
            (replyPositionMs != null && replyPositionMs >= 0)
                ? replyPositionMs
                : clampedMs;
        final durationMs = _duration.inMilliseconds;
        // Treat a seek as landing away from the endpoint whenever the user
        // requested a position strictly before `durationMs` AND native
        // confirmed landing strictly before `durationMs` (no artificial end
        // fudge window that would swallow legitimate near-end scrub-backs such
        // as 99.6s on a 100s clip or 1.28s on a 1.6s clip). Exact endpoint
        // seeks (`clampedMs >= durationMs`, e.g. +15s clamped to duration) or
        // native landings at `durationMs` keep endpoint completion intact.
        final landedAwayFromEnd =
            durationMs <= 0 ||
            (clampedMs < durationMs && landedMs < durationMs);
        final newerThanConfirmedEventSeq =
            replyEventSeq == null ||
            _confirmedSeekEventSeq == null ||
            replyEventSeq > _confirmedSeekEventSeq!;
        // Track completion-suppression watermark independently of whether a
        // fresher post-landing clock sample already won the position check:
        // - Scrubbing back away from the end supersedes older stale `completed`
        //   events even when a newer clock tick arrived before this seek reply.
        // - Seeking directly onto the media endpoint (`!landedAwayFromEnd`)
        //   MUST NOT suppress a genuine `completed` event at the endpoint.
        final isNewerSeekGen = seekGen > _confirmedSeekGen;
        if (isNewerSeekGen) {
          _confirmedSeekGen = seekGen;
          if (landedAwayFromEnd) {
            if (replyEventSeq != null &&
                (_completionSuppressMediaId != mediaId ||
                    _completionSuppressEventSeq == null ||
                    replyEventSeq > _completionSuppressEventSeq!)) {
              _completionSuppressMediaId = mediaId;
              _completionSuppressEventSeq = replyEventSeq;
            }
            final supersedesPendingCompletion =
                _pendingCompletedMediaId == mediaId &&
                (_pendingCompletedEventSeq == null ||
                    replyEventSeq == null ||
                    replyEventSeq >= _pendingCompletedEventSeq!);
            if (supersedesPendingCompletion) {
              _pendingCompletedMediaId = null;
              _pendingCompletedEventSeq = null;
            }
            if (_completed) {
              _completed = false;
            }
          }
          if (newerThanConfirmedEventSeq && !sampleSupersedesSeek) {
            _confirmedSeekPosition = Duration(milliseconds: landedMs);
            _confirmedSeekMediaId = mediaId;
            _confirmedSeekSampleSeq = _nativePositionSampleSeq;
            _confirmedSeekEventSeq = replyEventSeq;
          }
        }
        finishSeekAndReconcile();
      } else {
        _burstSeekTargets.remove(seekGen);
        finishSeekAndReconcile();
      }
      return nativeAccepted;
    } on MissingPluginException {
      _burstSeekTargets.remove(seekGen);
      finishSeekAndReconcile();
      return false;
    } catch (_) {
      _burstSeekTargets.remove(seekGen);
      finishSeekAndReconcile();
      return false;
    }
  }

  Future<void> setRate(double nextRate) async {
    if (!isSupportedPlatform || _disposed) return;
    _rate = nextRate.clamp(0.25, 4.0);
    _notify();
    try {
      await _channel.invokeMethod<void>('setRate', _rate);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setVolume(double nextVolume) async {
    if (!isSupportedPlatform || _disposed) return;
    _volume = nextVolume.clamp(0.0, 1.0);
    _notify();
    try {
      await _channel.invokeMethod<void>('setVolume', _volume);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  /// Reads the real iOS device hardware/system output volume in `[0.0, 1.0]`.
  Future<double?> getSystemVolume() async {
    if (!isSupportedPlatform || _disposed) return null;
    try {
      final raw = await _channel.invokeMethod<num>('getSystemVolume');
      if (raw == null) return null;
      final clamped = raw.toDouble().clamp(0.0, 1.0);
      _systemVolume = clamped;
      _hasSystemVolume = true;
      _notify();
      return clamped;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Updates the real iOS device hardware/system output volume in `[0.0, 1.0]`.
  ///
  /// Returns `({bool applied, double? confirmedVolume, double? observedVolume})`
  /// so callers can distinguish optimistic slider acceptance from an explicit
  /// hardware `observedVolume` reading and revert/reconcile HUD & drag baseline.
  Future<({bool applied, double? confirmedVolume, double? observedVolume})>
      setSystemVolumeDetailed(
    double volume01,
  ) async {
    if (!isSupportedPlatform || _disposed) {
      final cur = _hasSystemVolume ? _systemVolume : null;
      return (applied: false, confirmedVolume: cur, observedVolume: cur);
    }
    final clamped = volume01.clamp(0.0, 1.0);
    try {
      final raw = await _channel.invokeMethod<dynamic>('setSystemVolume', clamped);
      if (raw is Map) {
        final applied = raw['applied'] == true;
        final rawVol = raw['volume'];
        final rawObs = raw['observedVolume'];
        final confirmed = rawVol is num
            ? rawVol.toDouble().clamp(0.0, 1.0)
            : (_hasSystemVolume ? _systemVolume : null);
        final observed = rawObs is num
            ? rawObs.toDouble().clamp(0.0, 1.0)
            : (!applied ? confirmed : null);
        final storedVol = observed ?? confirmed;
        if (storedVol != null) {
          _systemVolume = storedVol;
          _hasSystemVolume = true;
          _notify();
        }
        return (
          applied: applied,
          confirmedVolume: confirmed,
          observedVolume: observed,
        );
      }
      if (raw is num) {
        final appliedVol = raw.toDouble().clamp(0.0, 1.0);
        _systemVolume = appliedVol;
        _hasSystemVolume = true;
        _notify();
        return (
          applied: true,
          confirmedVolume: appliedVol,
          observedVolume: null,
        );
      }
      final fallbackConfirmed = await getSystemVolume();
      final resolved = fallbackConfirmed ?? (_hasSystemVolume ? _systemVolume : null);
      return (
        applied: false,
        confirmedVolume: resolved,
        observedVolume: resolved,
      );
    } on MissingPluginException {
      final cur = _hasSystemVolume ? _systemVolume : null;
      return (applied: false, confirmedVolume: cur, observedVolume: cur);
    } catch (_) {
      final fallbackConfirmed = await getSystemVolume();
      final resolved = fallbackConfirmed ?? (_hasSystemVolume ? _systemVolume : null);
      return (
        applied: false,
        confirmedVolume: resolved,
        observedVolume: resolved,
      );
    }
  }

  /// Updates the real iOS device hardware/system output volume in `[0.0, 1.0]`.
  /// Returns the confirmed volume on success, or `null` if native write failed.
  Future<double?> setSystemVolume(double volume01) async {
    final res = await setSystemVolumeDetailed(volume01);
    return res.applied ? res.confirmedVolume : null;
  }

  /// Detaches the hidden native `MPVolumeView` once the player exits so
  /// system hardware volume buttons behave normally outside playback.
  Future<void> detachSystemVolume() async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('detachSystemVolume');
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  static Future<double?> readDefaultSystemVolume() async {
    if (kIsWeb || OhosRuntime.isOhos || defaultTargetPlatform != TargetPlatform.iOS) {
      return null;
    }
    try {
      final raw = await defaultChannel.invokeMethod<num>('getSystemVolume');
      return raw?.toDouble().clamp(0.0, 1.0);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<({bool applied, double? confirmedVolume, double? observedVolume})>
      writeDefaultSystemVolumeDetailed(double volume01) async {
    if (kIsWeb || OhosRuntime.isOhos || defaultTargetPlatform != TargetPlatform.iOS) {
      return (applied: false, confirmedVolume: null, observedVolume: null);
    }
    final clamped = volume01.clamp(0.0, 1.0);
    try {
      final raw = await defaultChannel.invokeMethod<dynamic>(
        'setSystemVolume',
        clamped,
      );
      if (raw is Map) {
        final applied = raw['applied'] == true;
        final rawVol = raw['volume'];
        final rawObs = raw['observedVolume'];
        final confirmed = rawVol is num
            ? rawVol.toDouble().clamp(0.0, 1.0)
            : await readDefaultSystemVolume();
        final observed = rawObs is num
            ? rawObs.toDouble().clamp(0.0, 1.0)
            : (!applied ? confirmed : null);
        return (
          applied: applied,
          confirmedVolume: confirmed,
          observedVolume: observed,
        );
      }
      if (raw is num) {
        return (
          applied: true,
          confirmedVolume: raw.toDouble().clamp(0.0, 1.0),
          observedVolume: null,
        );
      }
      final fallback = await readDefaultSystemVolume();
      return (applied: false, confirmedVolume: fallback, observedVolume: fallback);
    } on MissingPluginException {
      return (applied: false, confirmedVolume: null, observedVolume: null);
    } catch (_) {
      final fallback = await readDefaultSystemVolume();
      return (applied: false, confirmedVolume: fallback, observedVolume: fallback);
    }
  }

  static Future<double?> writeDefaultSystemVolume(double volume01) async {
    final res = await writeDefaultSystemVolumeDetailed(volume01);
    return res.applied ? res.confirmedVolume : null;
  }

  static Future<void> detachDefaultSystemVolume() async {
    if (kIsWeb || OhosRuntime.isOhos || defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      await defaultChannel.invokeMethod<void>('detachSystemVolume');
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setVideoGravity(String gravity) async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setVideoGravity', gravity);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<bool> startPip() async {
    if (!isSupportedPlatform || _disposed) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('startPip');
      if (ok == true) {
        // Do NOT mark `_isPipActive = true` optimistically before native emits
        // `didStart`; track pending native startup instead.
        _isPipStarting = !_isPipActive;
        _notify();
      } else {
        if (_isPipStarting) {
          _isPipStarting = false;
          _notify();
        }
      }
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopPip() async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('stopPip');
      _isPipStarting = false;
      _isPipActive = false;
      _notify();
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<void> setAutoPip(bool enabled) async {
    _autoPipEnabled = enabled;
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setAutoPip', enabled);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<bool> presentAirPlayPicker() async {
    if (!isSupportedPlatform || _disposed) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('presentAirPlayPicker');
      return ok == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setAudioTrack(String trackId) async {
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setAudioTrack', trackId);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  void _clearActiveSubtitleCue() {
    if (_activeSubtitleLines.isNotEmpty || _currentSubtitleHasNonTextSamples) {
      _activeSubtitleLines = const <String>[];
      _currentSubtitleHasNonTextSamples = false;
      if (!_subtitleCueCtrl.isClosed) {
        _subtitleCueCtrl.add((
          lines: const <String>[],
          hasNativeSamples: false,
        ));
      }
    }
  }

  Future<void> setSubtitleTrack(String? trackId) async {
    _clearActiveSubtitleCue();
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('setSubtitleTrack', trackId);
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  /// Coordinates native `AVPlayerItemLegibleOutput.suppressesPlayerRendering`
  /// with Flutter's AI subtitle overlay so original subtitles are never
  /// rendered twice inline while automatically restoring native rendering
  /// inside system Picture-in-Picture and across media handoffs.
  ///
  /// Set [allowNonText] to `true` ONLY when replacing native subtitles with an
  /// explicit external subtitle track (e.g. mounted SRT overlay) so graphical
  /// PGS/VobSub tracks do not double-render underneath the external SRT; leave
  /// `false` for live embedded translation so non-text tracks stay visible.
  Future<void> setSuppressNativeSubtitleRendering(
    bool suppress, {
    bool allowNonText = false,
    bool force = false,
  }) async {
    final effectiveAllowNonText = suppress && allowNonText;
    if (!force &&
        _suppressNativeSubtitleSynced &&
        _suppressNativeSubtitleRendering == suppress &&
        _suppressNativeSubtitleAllowNonText == effectiveAllowNonText) {
      return;
    }
    _suppressNativeSubtitleRendering = suppress;
    _suppressNativeSubtitleAllowNonText = effectiveAllowNonText;
    _suppressNativeSubtitleSynced = true;
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      final Object payload = effectiveAllowNonText
          ? <String, dynamic>{
              'suppress': true,
              'allowNonText': true,
              'mode': 'externalOverlay',
            }
          : suppress;
      await _channel.invokeMethod<void>(
        'setSuppressNativeSubtitleRendering',
        payload,
      );
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  Future<IosAvPlayerTelemetry?> refreshTelemetry() async {
    if (!isSupportedPlatform || _disposed) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getTelemetry',
      );
      if (raw == null) return null;
      final telemetry = IosAvPlayerTelemetry.fromMap(raw);
      _applyTelemetry(telemetry);
      _notify();
      return telemetry;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    _mediaId = null;
    _requestedPlaying = null;
    _playing = false;
    _buffering = false;
    _nativePositionSample = null;
    _nativePositionSampleEventSeq = null;
    _nativePositionSampleMediaId = null;
    _confirmedSeekPosition = null;
    _confirmedSeekMediaId = null;
    _confirmedSeekSampleSeq = -1;
    _confirmedSeekEventSeq = null;
    _seekGeneration++;
    _confirmedSeekGen = _seekGeneration;
    _latestSeekDispatchedSampleSeq = -1;
    _seekBurstOriginPosMs = null;
    _pendingCompletedMediaId = null;
    _pendingCompletedEventSeq = null;
    _completionSuppressMediaId = null;
    _completionSuppressEventSeq = null;
    _inFlightSeekGens.clear();
    _burstSeekTargets.clear();
    _activeSubtitleLines = const <String>[];
    _currentSubtitleHasNonTextSamples = false;
    _suppressNativeSubtitleRendering = false;
    _suppressNativeSubtitleAllowNonText = false;
    _suppressNativeSubtitleSynced = false;
    if (!_subtitleCueCtrl.isClosed) {
      _subtitleCueCtrl.add((
        lines: const <String>[],
        hasNativeSamples: false,
      ));
    }
    _notify();
    if (!isSupportedPlatform || _disposed) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Ignore in tests.
    } catch (_) {}
  }

  /// Renders the native zero-copy `AVPlayerLayer` `UiKitView` on iOS.
  Widget buildView({
    Key? key,
    VoidCallback? onPlatformViewCreated,
  }) {
    if (!isSupportedPlatform) {
      return SizedBox.expand(key: key);
    }
    return UiKitView(
      key: key,
      viewType: viewType,
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => onPlatformViewCreated?.call(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventSub?.cancel();
    _eventSub = null;
    _channel.setMethodCallHandler(null);
    _fallbackCtrl.close();
    _thermalCtrl.close();
    _pipCtrl.close();
    _pipErrorCtrl.close();
    _pipRestoreCtrl.close();
    _airPlayCtrl.close();
    _systemVolumeCtrl.close();
    _subtitleCueCtrl.close();
    super.dispose();
  }
}

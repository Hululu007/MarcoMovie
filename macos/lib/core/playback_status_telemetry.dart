// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Explicit user-visible playback loading phase distinguishing:
/// - [resolving]: CatPaw / SourcePlayback / cloud share play-URL resolution
/// - [connecting]: media URL handed to libmpv/proxy, awaiting first response bytes
/// - [buffering]: receiving media bytes / filling demuxer buffer (startup or seek)
/// - [idle]: active playback recovered (indicator hidden)
enum PlaybackLoadPhase {
  idle,
  resolving,
  connecting,
  buffering,
}

enum PlaybackLoadTrigger {
  startup,
  seek,
}

@immutable
class PlaybackStatusSnapshot {
  final PlaybackLoadPhase phase;
  final PlaybackLoadTrigger trigger;
  final double? networkBytesPerSecond;
  final double? bufferingPercent;
  final bool isLocalFile;

  const PlaybackStatusSnapshot({
    this.phase = PlaybackLoadPhase.idle,
    this.trigger = PlaybackLoadTrigger.startup,
    this.networkBytesPerSecond,
    this.bufferingPercent,
    this.isLocalFile = false,
  });

  bool get isVisible => phase != PlaybackLoadPhase.idle;

  String get phaseLabelZh => switch (phase) {
        PlaybackLoadPhase.idle => '',
        PlaybackLoadPhase.resolving => '正在解析',
        PlaybackLoadPhase.connecting => '正在连接',
        PlaybackLoadPhase.buffering => '正在缓冲',
      };

  static String formatSpeed(double bytesPerSecond) {
    if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '';
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.round()} B/s';
    }
    final kib = bytesPerSecond / 1024.0;
    if (kib < 1024.0) {
      return '${kib.toStringAsFixed(kib >= 100 ? 0 : 1)} KB/s';
    }
    final mib = kib / 1024.0;
    return '${mib.toStringAsFixed(mib >= 10 ? 1 : 2)} MB/s';
  }

  String formatLabel({required String episodeName}) {
    if (phase == PlaybackLoadPhase.idle) return '';
    final cleanName = episodeName.trim();
    final subject = (trigger == PlaybackLoadTrigger.seek || cleanName.isEmpty)
        ? ''
        : ' $cleanName';
    final base = '$phaseLabelZh$subject…';
    if (isLocalFile || phase == PlaybackLoadPhase.resolving) {
      return base;
    }
    final speed = networkBytesPerSecond;
    if (speed != null && speed.isFinite && speed > 0) {
      return '$base · ${formatSpeed(speed)}';
    }
    final pct = bufferingPercent;
    if (phase == PlaybackLoadPhase.buffering &&
        pct != null &&
        pct.isFinite &&
        pct > 0 &&
        pct < 100) {
      return '$base ${pct.round()}%';
    }
    return base;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackStatusSnapshot &&
      other.phase == phase &&
      other.trigger == trigger &&
      other.isLocalFile == isLocalFile &&
      ((other.networkBytesPerSecond == null && networkBytesPerSecond == null) ||
          (other.networkBytesPerSecond != null &&
              networkBytesPerSecond != null &&
              (other.networkBytesPerSecond! - networkBytesPerSecond!).abs() <
                  128)) &&
      other.bufferingPercent?.round() == bufferingPercent?.round();

  @override
  int get hashCode => Object.hash(
        phase,
        trigger,
        isLocalFile,
        networkBytesPerSecond == null ? null : (networkBytesPerSecond! ~/ 1024),
        bufferingPercent?.round(),
      );
}

class _ByteSample {
  final int timeMs;
  final int bytes;
  const _ByteSample(this.timeMs, this.bytes);
}

/// Rolling-window real network throughput meter.
///
/// Only accepts real upstream network byte transfers (from [LocalMediaLease],
/// [CloudMediaLease], or libmpv `cache-speed`). Never synthesizes fallback
/// speeds and expires stale samples once transfer stops.
class PlaybackThroughputMeter {
  final Duration window;
  final Duration staleAfter;
  final DateTime Function() _clock;

  final ListQueue<_ByteSample> _samples = ListQueue<_ByteSample>();
  int _windowBytes = 0;
  double? _mpvCacheSpeedBps;
  int _mpvCacheSpeedUpdatedAtMs = 0;
  int _totalRecordedBytes = 0;

  PlaybackThroughputMeter({
    this.window = const Duration(milliseconds: 2500),
    this.staleAfter = const Duration(milliseconds: 2500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  int get totalRecordedBytes => _totalRecordedBytes;

  void recordNetworkBytes(int bytes) {
    if (bytes <= 0) return;
    final nowMs = _clock().millisecondsSinceEpoch;
    _samples.addLast(_ByteSample(nowMs, bytes));
    _windowBytes += bytes;
    _totalRecordedBytes += bytes;
    _prune(nowMs);
  }

  void updateMpvCacheSpeed(double bytesPerSecond) {
    final nowMs = _clock().millisecondsSinceEpoch;
    if (bytesPerSecond.isFinite && bytesPerSecond > 0) {
      _mpvCacheSpeedBps = bytesPerSecond;
      _mpvCacheSpeedUpdatedAtMs = nowMs;
    } else {
      _mpvCacheSpeedBps = null;
      _mpvCacheSpeedUpdatedAtMs = 0;
    }
  }

  double? currentBytesPerSecond() {
    final nowMs = _clock().millisecondsSinceEpoch;
    _prune(nowMs);
    if (_samples.isNotEmpty && _windowBytes > 0) {
      final oldestMs = _samples.first.timeMs;
      final newestMs = _samples.last.timeMs;
      if (nowMs - newestMs <= staleAfter.inMilliseconds) {
        final spanMs = (nowMs - oldestMs).clamp(250, window.inMilliseconds);
        return (_windowBytes * 1000.0) / spanMs;
      }
    }
    final mpvSpeed = _mpvCacheSpeedBps;
    if (mpvSpeed != null &&
        mpvSpeed > 0 &&
        nowMs - _mpvCacheSpeedUpdatedAtMs <= staleAfter.inMilliseconds) {
      return mpvSpeed;
    }
    return null;
  }

  void clear() {
    _samples.clear();
    _windowBytes = 0;
    _mpvCacheSpeedBps = null;
    _mpvCacheSpeedUpdatedAtMs = 0;
  }

  void _prune(int nowMs) {
    final cutoffMs = nowMs - window.inMilliseconds;
    while (_samples.isNotEmpty && _samples.first.timeMs < cutoffMs) {
      _windowBytes -= _samples.removeFirst().bytes;
    }
    if (_windowBytes < 0) _windowBytes = 0;
  }
}

/// Coordinates startup & seek loading phase transitions with real throughput
/// readings for [PlayerScreen].
class PlaybackStatusController {
  final PlaybackThroughputMeter _meter;
  PlaybackLoadPhase _phase = PlaybackLoadPhase.idle;
  PlaybackLoadTrigger _trigger = PlaybackLoadTrigger.startup;
  bool _isLocalFile = false;
  bool _hasReceivedMediaBytes = false;
  double? _bufferingPercent;

  PlaybackStatusController({DateTime Function()? clock})
      : _meter = PlaybackThroughputMeter(clock: clock);

  PlaybackLoadPhase get phase => _phase;
  PlaybackLoadTrigger get trigger => _trigger;
  bool get isVisible => _phase != PlaybackLoadPhase.idle;
  int get totalNetworkBytesRecorded => _meter.totalRecordedBytes;

  PlaybackStatusSnapshot get snapshot => PlaybackStatusSnapshot(
        phase: _phase,
        trigger: _trigger,
        isLocalFile: _isLocalFile,
        networkBytesPerSecond:
            _isLocalFile ? null : _meter.currentBytesPerSecond(),
        bufferingPercent: _bufferingPercent,
      );

  /// Stage 1 (startup): resolving source play URL via CatPaw / SourcePlayback / cloud.
  void beginResolving({required bool isLocalFile}) {
    _meter.clear();
    _isLocalFile = isLocalFile;
    _hasReceivedMediaBytes = false;
    _bufferingPercent = null;
    _trigger = PlaybackLoadTrigger.startup;
    _phase = isLocalFile
        ? PlaybackLoadPhase.connecting
        : PlaybackLoadPhase.resolving;
  }

  /// Stage 2 (startup): play URL resolved and passed to media player/proxy,
  /// waiting for upstream connection and first media bytes.
  void beginConnecting({required bool isLocalFile}) {
    _isLocalFile = isLocalFile;
    _hasReceivedMediaBytes = false;
    _bufferingPercent = null;
    _trigger = PlaybackLoadTrigger.startup;
    _phase = PlaybackLoadPhase.connecting;
  }

  /// Seek triggered on a network stream: show buffering until playback resumes
  /// or seek completes inside buffer.
  void beginSeek({required bool isLocalFile}) {
    _isLocalFile = isLocalFile;
    if (isLocalFile) return;
    _trigger = PlaybackLoadTrigger.seek;
    _phase = PlaybackLoadPhase.buffering;
    _bufferingPercent = null;
  }

  /// Called when upstream HTTP/cloud proxy receives real network bytes
  /// (never called for local disk cache hits).
  void onNetworkBytesReceived(int bytes) {
    if (bytes <= 0 || _isLocalFile) return;
    _meter.recordNetworkBytes(bytes);
    _hasReceivedMediaBytes = true;
    if (_phase == PlaybackLoadPhase.connecting) {
      _phase = PlaybackLoadPhase.buffering;
    }
  }

  /// Called when libmpv reports real `cache-speed` (bytes/sec).
  void onMpvCacheSpeed(double bytesPerSecond) {
    if (_isLocalFile) return;
    _meter.updateMpvCacheSpeed(bytesPerSecond);
    if (bytesPerSecond > 0) {
      _hasReceivedMediaBytes = true;
      if (_phase == PlaybackLoadPhase.connecting) {
        _phase = PlaybackLoadPhase.buffering;
      }
    }
  }

  /// Called when `player.stream.buffering` or `bufferingPercentage` changes.
  void onBufferingStateChanged(
    bool buffering, {
    double? bufferingPercent,
    bool playbackActive = false,
  }) {
    if (bufferingPercent != null && bufferingPercent.isFinite) {
      _bufferingPercent = bufferingPercent.clamp(0.0, 100.0);
    }
    if (buffering) {
      if (_phase == PlaybackLoadPhase.resolving) {
        return;
      }
      if (_phase == PlaybackLoadPhase.connecting) {
        if (_hasReceivedMediaBytes ||
            (_bufferingPercent != null && _bufferingPercent! > 0)) {
          _phase = PlaybackLoadPhase.buffering;
        }
        return;
      }
      _phase = PlaybackLoadPhase.buffering;
    } else if (playbackActive) {
      onPlaybackRecovered();
    }
  }

  /// Called when libmpv `seeking` property changes.
  void onMpvSeekingChanged(bool seeking, {bool isBuffering = false}) {
    if (_isLocalFile) return;
    if (seeking) {
      if (_phase == PlaybackLoadPhase.idle) {
        _trigger = PlaybackLoadTrigger.seek;
        _phase = PlaybackLoadPhase.buffering;
      }
    } else if (!isBuffering && _trigger == PlaybackLoadTrigger.seek) {
      onPlaybackRecovered();
    }
  }

  /// Called when first frame renders or playback progress resumes after seek/stall.
  void onPlaybackRecovered() {
    _phase = PlaybackLoadPhase.idle;
    _bufferingPercent = null;
  }

  void reset() {
    _meter.clear();
    _phase = PlaybackLoadPhase.idle;
    _trigger = PlaybackLoadTrigger.startup;
    _hasReceivedMediaBytes = false;
    _bufferingPercent = null;
  }
}

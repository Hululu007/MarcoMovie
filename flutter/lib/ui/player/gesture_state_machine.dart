// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

/// Pure-logic states for the cross-platform touch gesture state machine.
enum TouchGestureState {
  idle,
  lockedIdle,
  downPending,
  waitDoubleTap,
  secondTapDown,
  multiTapSeekWindow,
  horizontalSeek,
  verticalBrightness,
  verticalVolume,
  longPressSpeed,
  speedLockReady,
  speedLocked,
  cancelled,
}

/// Screen horizontal region for double-tap & multi-tap seek disambiguation.
enum TapZone {
  left,
  center,
  right,
}

/// Standardized interruption reasons that guarantee safe transient cleanup.
enum GestureInterruptReason {
  pointerCancel,
  multiTouch,
  focusLost,
  lifecyclePause,
  audioFocusLost,
  pipEntered,
  dialogOpened,
  episodeSwitch,
  screenLock,
  manualSpeedChange,
  backExit,
  playbackPaused,
}

/// Configuration constants aligned 1:1 with `shared/ui-spec/motion-tokens.json`.
class TouchGestureConfig {
  final double touchSlopDp;
  final int doubleTapTimeoutMs;
  final double doubleTapSlopDp;
  final int multiTapSeekWindowMs;
  final double edgeBackGuardDp;
  final double systemVerticalGuardDp;
  final double speedSlideStepDp;
  final double swipeLockThresholdDp;
  final double swipeLockReleaseHysteresisDp;
  final int longPressSpeedThresholdMs;
  final List<double> speedDetents;
  final double defaultBoostSpeed;
  final String doubleTapCenterAction;
  final String doubleTapSidesAction;
  final String longPressRestoreMode;
  final bool enableVerticalDrags;
  final bool enableLongPressSpeed;
  final double leftZoneRatio;
  final double rightZoneRatio;

  const TouchGestureConfig({
    this.touchSlopDp = 12.0,
    this.doubleTapTimeoutMs = 260,
    this.doubleTapSlopDp = 42.0,
    this.multiTapSeekWindowMs = 650,
    this.edgeBackGuardDp = 24.0,
    this.systemVerticalGuardDp = 28.0,
    this.speedSlideStepDp = 36.0,
    this.swipeLockThresholdDp = 48.0,
    this.swipeLockReleaseHysteresisDp = 36.0,
    this.longPressSpeedThresholdMs = 350,
    this.speedDetents = const <double>[1.25, 1.5, 2.0, 3.0],
    this.defaultBoostSpeed = 2.0,
    this.doubleTapCenterAction = 'play_pause',
    this.doubleTapSidesAction = 'seek_10s',
    this.longPressRestoreMode = 'previous',
    this.enableVerticalDrags = true,
    this.enableLongPressSpeed = true,
    this.leftZoneRatio = 0.28,
    this.rightZoneRatio = 0.72,
  });

  TouchGestureConfig copyWith({
    double? touchSlopDp,
    int? doubleTapTimeoutMs,
    double? doubleTapSlopDp,
    int? multiTapSeekWindowMs,
    double? edgeBackGuardDp,
    double? systemVerticalGuardDp,
    double? speedSlideStepDp,
    double? swipeLockThresholdDp,
    double? swipeLockReleaseHysteresisDp,
    int? longPressSpeedThresholdMs,
    List<double>? speedDetents,
    double? defaultBoostSpeed,
    String? doubleTapCenterAction,
    String? doubleTapSidesAction,
    String? longPressRestoreMode,
    bool? enableVerticalDrags,
    bool? enableLongPressSpeed,
    double? leftZoneRatio,
    double? rightZoneRatio,
  }) {
    return TouchGestureConfig(
      touchSlopDp: touchSlopDp ?? this.touchSlopDp,
      doubleTapTimeoutMs: doubleTapTimeoutMs ?? this.doubleTapTimeoutMs,
      doubleTapSlopDp: doubleTapSlopDp ?? this.doubleTapSlopDp,
      multiTapSeekWindowMs: multiTapSeekWindowMs ?? this.multiTapSeekWindowMs,
      edgeBackGuardDp: edgeBackGuardDp ?? this.edgeBackGuardDp,
      systemVerticalGuardDp:
          systemVerticalGuardDp ?? this.systemVerticalGuardDp,
      speedSlideStepDp: speedSlideStepDp ?? this.speedSlideStepDp,
      swipeLockThresholdDp: swipeLockThresholdDp ?? this.swipeLockThresholdDp,
      swipeLockReleaseHysteresisDp:
          swipeLockReleaseHysteresisDp ?? this.swipeLockReleaseHysteresisDp,
      longPressSpeedThresholdMs:
          longPressSpeedThresholdMs ?? this.longPressSpeedThresholdMs,
      speedDetents: speedDetents ?? this.speedDetents,
      defaultBoostSpeed: defaultBoostSpeed ?? this.defaultBoostSpeed,
      doubleTapCenterAction:
          doubleTapCenterAction ?? this.doubleTapCenterAction,
      doubleTapSidesAction: doubleTapSidesAction ?? this.doubleTapSidesAction,
      longPressRestoreMode: longPressRestoreMode ?? this.longPressRestoreMode,
      enableVerticalDrags: enableVerticalDrags ?? this.enableVerticalDrags,
      enableLongPressSpeed: enableLongPressSpeed ?? this.enableLongPressSpeed,
      leftZoneRatio: leftZoneRatio ?? this.leftZoneRatio,
      rightZoneRatio: rightZoneRatio ?? this.rightZoneRatio,
    );
  }

  int get sideSeekSeconds => switch (doubleTapSidesAction) {
        'seek_5s' => 5,
        'seek_10s' => 10,
        'seek_15s' => 15,
        _ => 0,
      };
}

/// Snapshot of player & viewport state supplied when a gesture starts.
class TouchPointerContext {
  final int pointerId;
  final double x;
  final double y;
  final double viewportWidth;
  final double viewportHeight;
  final double systemGestureInsetLeft;
  final double systemGestureInsetRight;
  final double systemInsetTop;
  final double systemInsetBottom;
  final int nowMs;
  final bool screenLocked;
  final bool isLive;
  final bool isPipOrMini;
  final bool playing;
  final int durationMs;
  final int positionMs;
  final double userNormalSpeed;
  final double brightness;
  final double volume;
  final bool startedInsideDock;
  final bool dialogOpen;
  final bool isTouchPointer;

  const TouchPointerContext({
    required this.pointerId,
    required this.x,
    required this.y,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.nowMs,
    this.systemGestureInsetLeft = 0.0,
    this.systemGestureInsetRight = 0.0,
    this.systemInsetTop = 0.0,
    this.systemInsetBottom = 0.0,
    this.screenLocked = false,
    this.isLive = false,
    this.isPipOrMini = false,
    this.playing = true,
    this.durationMs = 0,
    this.positionMs = 0,
    this.userNormalSpeed = 1.0,
    this.brightness = 1.0,
    this.volume = 1.0,
    this.startedInsideDock = false,
    this.dialogOpen = false,
    this.isTouchPointer = true,
  });
}

/// Output actions emitted by [PlayerGestureStateMachine].
sealed class TouchGestureEvent {
  const TouchGestureEvent();
}

class ToggleControlsEvent extends TouchGestureEvent {
  const ToggleControlsEvent();
}

class ToggleLockedControlsEvent extends TouchGestureEvent {
  const ToggleLockedControlsEvent();
}

class TogglePlayPauseEvent extends TouchGestureEvent {
  const TogglePlayPauseEvent();
}

class ToggleFullscreenEvent extends TouchGestureEvent {
  const ToggleFullscreenEvent();
}

class DoubleTapSeekEvent extends TouchGestureEvent {
  final int deltaSec;
  final int totalAccumulatedSec;
  final TapZone side;
  const DoubleTapSeekEvent({
    required this.deltaSec,
    required this.totalAccumulatedSec,
    required this.side,
  });
}

class MultiTapSeekEndEvent extends TouchGestureEvent {
  final int totalAccumulatedSec;
  const MultiTapSeekEndEvent({required this.totalAccumulatedSec});
}

class HorizontalSeekStartEvent extends TouchGestureEvent {
  final int startPositionMs;
  const HorizontalSeekStartEvent({required this.startPositionMs});
}

class HorizontalSeekUpdateEvent extends TouchGestureEvent {
  final int previewPositionMs;
  final int deltaMs;
  const HorizontalSeekUpdateEvent({
    required this.previewPositionMs,
    required this.deltaMs,
  });
}

class HorizontalSeekCommitEvent extends TouchGestureEvent {
  final int targetPositionMs;
  const HorizontalSeekCommitEvent({required this.targetPositionMs});
}

class HorizontalSeekCancelEvent extends TouchGestureEvent {
  const HorizontalSeekCancelEvent();
}

class VerticalBrightnessUpdateEvent extends TouchGestureEvent {
  final double brightness;
  const VerticalBrightnessUpdateEvent({required this.brightness});
}

class VerticalBrightnessEndEvent extends TouchGestureEvent {
  final double brightness;
  const VerticalBrightnessEndEvent({required this.brightness});
}

class VerticalVolumeUpdateEvent extends TouchGestureEvent {
  final double volume;
  const VerticalVolumeUpdateEvent({required this.volume});
}

class VerticalVolumeEndEvent extends TouchGestureEvent {
  final double volume;
  const VerticalVolumeEndEvent({required this.volume});
}

class SpeedBoostStartEvent extends TouchGestureEvent {
  final double speed;
  final int detentIndex;
  final List<double> detents;
  final bool haptic;
  const SpeedBoostStartEvent({
    required this.speed,
    required this.detentIndex,
    required this.detents,
    this.haptic = true,
  });
}

class SpeedBoostChangeEvent extends TouchGestureEvent {
  final double speed;
  final int detentIndex;
  final List<double> detents;
  final bool lockReady;
  final bool haptic;
  const SpeedBoostChangeEvent({
    required this.speed,
    required this.detentIndex,
    required this.detents,
    required this.lockReady,
    this.haptic = true,
  });
}

class SpeedLockReadyChangedEvent extends TouchGestureEvent {
  final bool lockReady;
  final double speed;
  final bool haptic;
  const SpeedLockReadyChangedEvent({
    required this.lockReady,
    required this.speed,
    this.haptic = false,
  });
}

class SpeedBoostEndEvent extends TouchGestureEvent {
  final double restoreSpeed;
  const SpeedBoostEndEvent({required this.restoreSpeed});
}

class SpeedLockedEvent extends TouchGestureEvent {
  final double speed;
  final bool haptic;
  const SpeedLockedEvent({required this.speed, this.haptic = true});
}

class SpeedUnlockedEvent extends TouchGestureEvent {
  final double restoreSpeed;
  final GestureInterruptReason? reason;
  const SpeedUnlockedEvent({required this.restoreSpeed, this.reason});
}

class GestureCancelledEvent extends TouchGestureEvent {
  final GestureInterruptReason reason;
  final double? restoredSpeed;
  const GestureCancelledEvent({required this.reason, this.restoredSpeed});
}

/// Deterministic, UI-independent touch gesture finite state machine.
class PlayerGestureStateMachine {
  TouchGestureConfig config;
  TouchGestureState _state = TouchGestureState.idle;
  bool _screenLocked = false;

  // Active pointer tracking for multi-touch cancellation.
  final Set<int> _activePointers = <int>{};
  int? _primaryPointerId;

  // Current pointer & context snapshot captured on down.
  double _downX = 0;
  double _downY = 0;
  double _currentX = 0;
  double _currentY = 0;
  double _maxMovementDp = 0;
  int _downMs = 0;
  double _viewportWidth = 1;
  double _viewportHeight = 1;
  bool _isLive = false;
  int _durationMs = 0;
  int _startPositionMs = 0;
  double _preBoostNormalSpeed = 1.0;
  double _startBrightness = 1.0;
  double _startVolume = 1.0;
  double _currentBrightness = 1.0;
  double _currentVolume = 1.0;
  bool _canLongPressSpeed = false;

  // Horizontal seek preview state.
  int _previewPositionMs = 0;

  // Double-tap & multi-tap seek state.
  double _firstTapX = 0;
  double _firstTapY = 0;
  int _firstTapUpMs = 0;
  bool _continuingMultiTap = false;
  TapZone _multiTapSide = TapZone.center;
  int _multiTapAccumulatedSec = 0;
  int _multiTapLastUpMs = 0;

  // Long-press speed boost & swipe-up lock state.
  double _speedAnchorX = 0;
  double _speedAnchorY = 0;
  int _anchorDetentIndex = 2;
  int _currentDetentIndex = 2;
  double _activeBoostSpeed = 2.0;
  bool _isSpeedLocked = false;
  double _lockedSpeed = 2.0;
  double _lockedRestoreSpeed = 1.0;

  // Pending timer deadline in epoch ms (null if no timer needed).
  int? _pendingDeadlineMs;
  GestureInterruptReason? _lastInterruptReason;

  PlayerGestureStateMachine({
    this.config = const TouchGestureConfig(),
  });

  TouchGestureState get state => _state;
  bool get isScreenLocked => _screenLocked;
  bool get isSpeedBoosting =>
      _state == TouchGestureState.longPressSpeed ||
      _state == TouchGestureState.speedLockReady;
  bool get isSpeedLockReady => _state == TouchGestureState.speedLockReady;
  bool get isSpeedLocked => _isSpeedLocked;
  double get activeSpeed => isSpeedBoosting
      ? _activeBoostSpeed
      : (_isSpeedLocked ? _lockedSpeed : _preBoostNormalSpeed);
  int get activeDetentIndex => _currentDetentIndex;
  int get previewPositionMs => _previewPositionMs;
  int? get nextTimerDeadlineMs => _pendingDeadlineMs;
  GestureInterruptReason? get lastInterruptReason => _lastInterruptReason;

  TouchGestureState get _restingState {
    if (_screenLocked) return TouchGestureState.lockedIdle;
    if (_isSpeedLocked) return TouchGestureState.speedLocked;
    return TouchGestureState.idle;
  }

  double get _resolvedRestoreSpeed =>
      config.longPressRestoreMode == '1.0x' ? 1.0 : _preBoostNormalSpeed;

  double get _resolvedLockedRestoreSpeed =>
      config.longPressRestoreMode == '1.0x' ? 1.0 : _lockedRestoreSpeed;

  /// Updates screen-lock state; locking immediately cancels transient gestures
  /// and unlocks any locked temporary speed.
  List<TouchGestureEvent> setScreenLocked(bool locked) {
    if (_screenLocked == locked) return const <TouchGestureEvent>[];
    if (locked) {
      final events = cancel(GestureInterruptReason.screenLock);
      _screenLocked = true;
      _state = TouchGestureState.lockedIdle;
      return events;
    }
    _screenLocked = false;
    _pendingDeadlineMs = null;
    _activePointers.clear();
    _primaryPointerId = null;
    _state = _isSpeedLocked
        ? TouchGestureState.speedLocked
        : TouchGestureState.idle;
    return const <TouchGestureEvent>[];
  }

  /// Syncs the user's normal playback speed (e.g. from speed picker or `S`/`[`/`]`).
  /// When speed was locked, manually choosing a speed exits [TouchGestureState.speedLocked].
  List<TouchGestureEvent> onManualSpeedChanged(double newNormalSpeed) {
    _preBoostNormalSpeed = newNormalSpeed;
    if (_isSpeedLocked) {
      _isSpeedLocked = false;
      _lockedRestoreSpeed = newNormalSpeed;
      if (_state == TouchGestureState.speedLocked) {
        _state = _screenLocked
            ? TouchGestureState.lockedIdle
            : TouchGestureState.idle;
      }
      return <TouchGestureEvent>[
        SpeedUnlockedEvent(
          restoreSpeed: newNormalSpeed,
          reason: GestureInterruptReason.manualSpeedChange,
        ),
      ];
    }
    return const <TouchGestureEvent>[];
  }

  /// Tapping the top compact locked-speed capsule unlocks speed immediately.
  List<TouchGestureEvent> unlockSpeed() {
    if (!_isSpeedLocked) return const <TouchGestureEvent>[];
    final restore = _resolvedLockedRestoreSpeed;
    _isSpeedLocked = false;
    if (_state == TouchGestureState.speedLocked) {
      _state = _screenLocked
          ? TouchGestureState.lockedIdle
          : TouchGestureState.idle;
    }
    return <TouchGestureEvent>[
      SpeedUnlockedEvent(restoreSpeed: restore),
    ];
  }

  bool _isInsideGuardZone(TouchPointerContext ctx) {
    final leftGuard =
        math.max(config.edgeBackGuardDp, ctx.systemGestureInsetLeft);
    final rightGuard =
        math.max(config.edgeBackGuardDp, ctx.systemGestureInsetRight);
    final topGuard = math.max(config.systemVerticalGuardDp, ctx.systemInsetTop);
    final bottomGuard =
        math.max(config.systemVerticalGuardDp, ctx.systemInsetBottom);
    if (ctx.x < leftGuard || ctx.x > ctx.viewportWidth - rightGuard) {
      return true;
    }
    if (ctx.y < topGuard || ctx.y > ctx.viewportHeight - bottomGuard) {
      return true;
    }
    return false;
  }

  TapZone _zoneForX(double x, double width) {
    if (width <= 0) return TapZone.center;
    final ratio = x / width;
    if (ratio < config.leftZoneRatio) return TapZone.left;
    if (ratio > config.rightZoneRatio) return TapZone.right;
    return TapZone.center;
  }

  List<TouchGestureEvent> onPointerDown(TouchPointerContext ctx) {
    if (ctx.screenLocked != _screenLocked) {
      _screenLocked = ctx.screenLocked;
      if (_screenLocked) {
        _state = TouchGestureState.lockedIdle;
      }
    }

    // Second simultaneous finger cancels any active gesture and unlocks speed.
    if (_activePointers.isNotEmpty && !_activePointers.contains(ctx.pointerId)) {
      _activePointers.add(ctx.pointerId);
      return cancel(GestureInterruptReason.multiTouch);
    }

    if (ctx.isPipOrMini || ctx.dialogOpen || ctx.startedInsideDock) {
      return const <TouchGestureEvent>[];
    }

    if (_isInsideGuardZone(ctx)) {
      return const <TouchGestureEvent>[];
    }

    // Handle locked screen: only allow tracking a single tap to toggle unlock capsule.
    if (_screenLocked || _state == TouchGestureState.lockedIdle) {
      _state = TouchGestureState.lockedIdle;
      _activePointers
        ..clear()
        ..add(ctx.pointerId);
      _primaryPointerId = ctx.pointerId;
      _downX = ctx.x;
      _downY = ctx.y;
      _currentX = ctx.x;
      _currentY = ctx.y;
      _maxMovementDp = 0;
      _downMs = ctx.nowMs;
      _pendingDeadlineMs = null;
      return const <TouchGestureEvent>[];
    }

    final events = <TouchGestureEvent>[];

    // Check continuation of multi-tap seek window (650ms).
    if (_state == TouchGestureState.multiTapSeekWindow) {
      final elapsed = ctx.nowMs - _multiTapLastUpMs;
      final zone = _zoneForX(ctx.x, ctx.viewportWidth);
      if (elapsed <= config.multiTapSeekWindowMs && zone == _multiTapSide) {
        _beginPointerTracking(ctx);
        _continuingMultiTap = true;
        _pendingDeadlineMs = null;
        _state = TouchGestureState.secondTapDown;
        return events;
      }
      // Different zone or expired: finish multi-tap cleanly without toggling controls.
      final total = _multiTapAccumulatedSec;
      _multiTapAccumulatedSec = 0;
      _pendingDeadlineMs = null;
      _state = _restingState;
      events.add(MultiTapSeekEndEvent(totalAccumulatedSec: total));
      return events;
    }

    // Check second tap inside 260ms double-tap window.
    if (_state == TouchGestureState.waitDoubleTap) {
      final elapsed = ctx.nowMs - _firstTapUpMs;
      final dist = math.sqrt(
        math.pow(ctx.x - _firstTapX, 2) + math.pow(ctx.y - _firstTapY, 2),
      );
      if (elapsed <= config.doubleTapTimeoutMs &&
          dist <= config.doubleTapSlopDp) {
        _beginPointerTracking(ctx);
        _continuingMultiTap = false;
        _pendingDeadlineMs = null;
        _state = TouchGestureState.secondTapDown;
        return events;
      }
      // Out-of-zone or already past timeout: settle first tap as single tap,
      // then start a fresh press.
      _pendingDeadlineMs = null;
      events.add(const ToggleControlsEvent());
    }

    _beginPointerTracking(ctx);
    _continuingMultiTap = false;
    _state = TouchGestureState.downPending;
    _pendingDeadlineMs = _canLongPressSpeed
        ? ctx.nowMs + config.longPressSpeedThresholdMs
        : null;
    return events;
  }

  void _beginPointerTracking(TouchPointerContext ctx) {
    _activePointers
      ..clear()
      ..add(ctx.pointerId);
    _primaryPointerId = ctx.pointerId;
    _downX = ctx.x;
    _downY = ctx.y;
    _currentX = ctx.x;
    _currentY = ctx.y;
    _maxMovementDp = 0;
    _downMs = ctx.nowMs;
    _viewportWidth = math.max(1.0, ctx.viewportWidth);
    _viewportHeight = math.max(1.0, ctx.viewportHeight);
    _isLive = ctx.isLive;
    _durationMs = math.max(0, ctx.durationMs);
    _startPositionMs = ctx.positionMs.clamp(0, math.max(0, ctx.durationMs));
    _previewPositionMs = _startPositionMs;
    if (!_isSpeedLocked) {
      _preBoostNormalSpeed = ctx.userNormalSpeed;
    }
    _startBrightness = ctx.brightness.clamp(0.08, 1.0);
    _currentBrightness = _startBrightness;
    _startVolume = ctx.volume.clamp(0.0, 1.0);
    _currentVolume = _startVolume;
    _canLongPressSpeed = config.enableLongPressSpeed &&
        ctx.isTouchPointer &&
        !ctx.isLive &&
        ctx.playing &&
        ctx.durationMs > 0;
  }

  List<TouchGestureEvent> onPointerMove({
    required int pointerId,
    required double x,
    required double y,
    required int nowMs,
  }) {
    if (_primaryPointerId == null || pointerId != _primaryPointerId) {
      return const <TouchGestureEvent>[];
    }

    _currentX = x;
    _currentY = y;
    final dx = x - _downX;
    final dy = y - _downY;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist > _maxMovementDp) _maxMovementDp = dist;

    if (_state == TouchGestureState.lockedIdle) {
      return const <TouchGestureEvent>[];
    }

    // Disambiguate initial move from DOWN_PENDING or SECOND_TAP_DOWN.
    if (_state == TouchGestureState.downPending ||
        _state == TouchGestureState.secondTapDown) {
      if (dist <= config.touchSlopDp) {
        // Still within stationary slop: check whether hold threshold elapsed.
        if (_state == TouchGestureState.downPending &&
            _canLongPressSpeed &&
            nowMs - _downMs >= config.longPressSpeedThresholdMs) {
          return _enterLongPressSpeed();
        }
        return const <TouchGestureEvent>[];
      }

      // Movement exceeded touchSlop: cancel any pending long-press timer!
      _pendingDeadlineMs = null;

      if (dx.abs() >= 1.15 * dy.abs()) {
        if (!_isLive && _durationMs > 0) {
          _state = TouchGestureState.horizontalSeek;
          final preview = _computeHorizontalSeekPreview(dx);
          _previewPositionMs = preview;
          return <TouchGestureEvent>[
            HorizontalSeekStartEvent(startPositionMs: _startPositionMs),
            HorizontalSeekUpdateEvent(
              previewPositionMs: preview,
              deltaMs: preview - _startPositionMs,
            ),
          ];
        }
        return const <TouchGestureEvent>[];
      }

      if (dy.abs() > dx.abs() && config.enableVerticalDrags) {
        if (_downX < _viewportWidth * 0.5) {
          _state = TouchGestureState.verticalBrightness;
          final nextB = _computeVerticalValue(_startBrightness, dy, 0.08, 1.0);
          _currentBrightness = nextB;
          return <TouchGestureEvent>[
            VerticalBrightnessUpdateEvent(brightness: nextB),
          ];
        } else {
          _state = TouchGestureState.verticalVolume;
          final nextV = _computeVerticalValue(_startVolume, dy, 0.0, 1.0);
          _currentVolume = nextV;
          return <TouchGestureEvent>[
            VerticalVolumeUpdateEvent(volume: nextV),
          ];
        }
      }
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.horizontalSeek) {
      final preview = _computeHorizontalSeekPreview(dx);
      _previewPositionMs = preview;
      return <TouchGestureEvent>[
        HorizontalSeekUpdateEvent(
          previewPositionMs: preview,
          deltaMs: preview - _startPositionMs,
        ),
      ];
    }

    if (_state == TouchGestureState.verticalBrightness) {
      final nextB = _computeVerticalValue(_startBrightness, dy, 0.08, 1.0);
      _currentBrightness = nextB;
      return <TouchGestureEvent>[
        VerticalBrightnessUpdateEvent(brightness: nextB),
      ];
    }

    if (_state == TouchGestureState.verticalVolume) {
      final nextV = _computeVerticalValue(_startVolume, dy, 0.0, 1.0);
      _currentVolume = nextV;
      return <TouchGestureEvent>[
        VerticalVolumeUpdateEvent(volume: nextV),
      ];
    }

    if (_state == TouchGestureState.longPressSpeed ||
        _state == TouchGestureState.speedLockReady) {
      final events = <TouchGestureEvent>[];
      final slideDx = x - _speedAnchorX;
      final slideDy = y - _speedAnchorY;

      // Horizontal detent switching every `speedSlideStepDp` (36dp).
      if (config.speedDetents.isNotEmpty && config.speedSlideStepDp > 0) {
        final stepDelta = (slideDx / config.speedSlideStepDp).truncate();
        final targetIdx = (_anchorDetentIndex + stepDelta)
            .clamp(0, config.speedDetents.length - 1);
        if (targetIdx != _currentDetentIndex) {
          _currentDetentIndex = targetIdx;
          _activeBoostSpeed = config.speedDetents[targetIdx];
          events.add(
            SpeedBoostChangeEvent(
              speed: _activeBoostSpeed,
              detentIndex: targetIdx,
              detents: config.speedDetents,
              lockReady: _state == TouchGestureState.speedLockReady,
              haptic: true,
            ),
          );
        }
      }

      // Vertical swipe-up lock with hysteresis (-48dp enter / -36dp release).
      if (_state == TouchGestureState.longPressSpeed &&
          slideDy <= -config.swipeLockThresholdDp) {
        _state = TouchGestureState.speedLockReady;
        events.add(
          SpeedLockReadyChangedEvent(
            lockReady: true,
            speed: _activeBoostSpeed,
            haptic: true,
          ),
        );
      } else if (_state == TouchGestureState.speedLockReady &&
          slideDy > -config.swipeLockReleaseHysteresisDp) {
        _state = TouchGestureState.longPressSpeed;
        events.add(
          SpeedLockReadyChangedEvent(
            lockReady: false,
            speed: _activeBoostSpeed,
            haptic: false,
          ),
        );
      }
      return events;
    }

    return const <TouchGestureEvent>[];
  }

  List<TouchGestureEvent> onPointerUp({
    required int pointerId,
    required double x,
    required double y,
    required int nowMs,
  }) {
    _activePointers.remove(pointerId);
    if (_primaryPointerId == null || pointerId != _primaryPointerId) {
      return const <TouchGestureEvent>[];
    }
    _primaryPointerId = null;

    final dx = x - _downX;
    final dy = y - _downY;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist > _maxMovementDp) _maxMovementDp = dist;

    if (_state == TouchGestureState.lockedIdle) {
      if (_maxMovementDp <= config.touchSlopDp &&
          nowMs - _downMs < config.longPressSpeedThresholdMs) {
        return const <TouchGestureEvent>[ToggleLockedControlsEvent()];
      }
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.downPending) {
      _pendingDeadlineMs = null;
      if (_maxMovementDp <= config.touchSlopDp) {
        final elapsed = nowMs - _downMs;
        final doubleTapDisabled = config.doubleTapCenterAction == 'none' &&
            config.doubleTapSidesAction == 'none';
        if (elapsed < config.doubleTapTimeoutMs && !doubleTapDisabled) {
          _firstTapX = x;
          _firstTapY = y;
          _firstTapUpMs = nowMs;
          _state = TouchGestureState.waitDoubleTap;
          _pendingDeadlineMs = nowMs + config.doubleTapTimeoutMs;
          return const <TouchGestureEvent>[];
        }
        _state = _restingState;
        return const <TouchGestureEvent>[ToggleControlsEvent()];
      }
      _state = _restingState;
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.secondTapDown) {
      _pendingDeadlineMs = null;
      if (_maxMovementDp > config.touchSlopDp) {
        _state = _restingState;
        return const <TouchGestureEvent>[];
      }
      final zone = _zoneForX(x, _viewportWidth);
      if (_continuingMultiTap) {
        final step = _sideStepSeconds(_multiTapSide);
        if (step != 0 && !_isLive && _durationMs > 0) {
          _multiTapAccumulatedSec += step;
          _multiTapLastUpMs = nowMs;
          _state = TouchGestureState.multiTapSeekWindow;
          _pendingDeadlineMs = nowMs + config.multiTapSeekWindowMs;
          return <TouchGestureEvent>[
            DoubleTapSeekEvent(
              deltaSec: step,
              totalAccumulatedSec: _multiTapAccumulatedSec,
              side: _multiTapSide,
            ),
          ];
        }
        _state = _restingState;
        return const <TouchGestureEvent>[];
      }

      if (zone == TapZone.center) {
        _state = _restingState;
        return _executeDiscreteDoubleTapAction(config.doubleTapCenterAction);
      }

      // Left or right side zone.
      final sideAction = config.doubleTapSidesAction;
      final sideStep = _sideStepSeconds(zone);
      if (sideStep != 0 && !_isLive && _durationMs > 0) {
        _multiTapSide = zone;
        _multiTapAccumulatedSec = sideStep;
        _multiTapLastUpMs = nowMs;
        _state = TouchGestureState.multiTapSeekWindow;
        _pendingDeadlineMs = nowMs + config.multiTapSeekWindowMs;
        return <TouchGestureEvent>[
          DoubleTapSeekEvent(
            deltaSec: sideStep,
            totalAccumulatedSec: sideStep,
            side: zone,
          ),
        ];
      }
      _state = _restingState;
      if (sideAction == 'fullscreen') {
        return const <TouchGestureEvent>[ToggleFullscreenEvent()];
      }
      if (sideAction == 'play_pause' || _isLive) {
        return const <TouchGestureEvent>[TogglePlayPauseEvent()];
      }
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.horizontalSeek) {
      final target = _previewPositionMs.clamp(0, _durationMs);
      _state = _restingState;
      return <TouchGestureEvent>[
        HorizontalSeekCommitEvent(targetPositionMs: target),
      ];
    }

    if (_state == TouchGestureState.verticalBrightness) {
      final b = _currentBrightness;
      _state = _restingState;
      return <TouchGestureEvent>[VerticalBrightnessEndEvent(brightness: b)];
    }

    if (_state == TouchGestureState.verticalVolume) {
      final v = _currentVolume;
      _state = _restingState;
      return <TouchGestureEvent>[VerticalVolumeEndEvent(volume: v)];
    }

    if (_state == TouchGestureState.longPressSpeed) {
      final restore = _resolvedRestoreSpeed;
      _isSpeedLocked = false;
      _state = _screenLocked
          ? TouchGestureState.lockedIdle
          : TouchGestureState.idle;
      return <TouchGestureEvent>[SpeedBoostEndEvent(restoreSpeed: restore)];
    }

    if (_state == TouchGestureState.speedLockReady) {
      _isSpeedLocked = true;
      _lockedSpeed = _activeBoostSpeed;
      _lockedRestoreSpeed = _preBoostNormalSpeed;
      _state = TouchGestureState.speedLocked;
      return <TouchGestureEvent>[
        SpeedLockedEvent(speed: _lockedSpeed, haptic: true),
      ];
    }

    return const <TouchGestureEvent>[];
  }

  /// Advances pending timers (`downPending` -> 350ms long-press, `waitDoubleTap`
  /// -> 260ms single tap, `multiTapSeekWindow` -> 650ms window close).
  List<TouchGestureEvent> onTick(int nowMs) {
    final deadline = _pendingDeadlineMs;
    if (deadline == null || nowMs < deadline) {
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.downPending) {
      _pendingDeadlineMs = null;
      if (_primaryPointerId != null &&
          _canLongPressSpeed &&
          _maxMovementDp <= config.touchSlopDp) {
        return _enterLongPressSpeed();
      }
      return const <TouchGestureEvent>[];
    }

    if (_state == TouchGestureState.waitDoubleTap) {
      _pendingDeadlineMs = null;
      _state = _restingState;
      return const <TouchGestureEvent>[ToggleControlsEvent()];
    }

    if (_state == TouchGestureState.multiTapSeekWindow) {
      _pendingDeadlineMs = null;
      final total = _multiTapAccumulatedSec;
      _multiTapAccumulatedSec = 0;
      _state = _restingState;
      return <TouchGestureEvent>[
        MultiTapSeekEndEvent(totalAccumulatedSec: total),
      ];
    }

    _pendingDeadlineMs = null;
    return const <TouchGestureEvent>[];
  }

  /// Cancels all transient gesture states safely, transitioning through
  /// [TouchGestureState.cancelled] to [TouchGestureState.idle] (or
  /// [TouchGestureState.lockedIdle]).
  List<TouchGestureEvent> cancel(GestureInterruptReason reason) {
    _lastInterruptReason = reason;
    _pendingDeadlineMs = null;
    _primaryPointerId = null;
    if (reason != GestureInterruptReason.multiTouch) {
      _activePointers.clear();
    }

    final events = <TouchGestureEvent>[];
    double? restoredSpeed;

    switch (_state) {
      case TouchGestureState.horizontalSeek:
        events.add(const HorizontalSeekCancelEvent());
      case TouchGestureState.verticalBrightness:
        events.add(VerticalBrightnessEndEvent(brightness: _currentBrightness));
      case TouchGestureState.verticalVolume:
        events.add(VerticalVolumeEndEvent(volume: _currentVolume));
      case TouchGestureState.longPressSpeed:
      case TouchGestureState.speedLockReady:
        restoredSpeed = _resolvedRestoreSpeed;
        _isSpeedLocked = false;
        events.add(SpeedBoostEndEvent(restoreSpeed: restoredSpeed));
      case TouchGestureState.multiTapSeekWindow:
        final total = _multiTapAccumulatedSec;
        _multiTapAccumulatedSec = 0;
        events.add(MultiTapSeekEndEvent(totalAccumulatedSec: total));
      case TouchGestureState.idle:
      case TouchGestureState.lockedIdle:
      case TouchGestureState.downPending:
      case TouchGestureState.waitDoubleTap:
      case TouchGestureState.secondTapDown:
      case TouchGestureState.speedLocked:
      case TouchGestureState.cancelled:
        break;
    }

    const unlockReasons = <GestureInterruptReason>{
      GestureInterruptReason.episodeSwitch,
      GestureInterruptReason.screenLock,
      GestureInterruptReason.backExit,
      GestureInterruptReason.lifecyclePause,
      GestureInterruptReason.multiTouch,
      GestureInterruptReason.pipEntered,
      GestureInterruptReason.audioFocusLost,
      GestureInterruptReason.playbackPaused,
      GestureInterruptReason.manualSpeedChange,
    };

    if (_isSpeedLocked && unlockReasons.contains(reason)) {
      _isSpeedLocked = false;
      if (reason != GestureInterruptReason.manualSpeedChange) {
        final unlockTarget = _resolvedLockedRestoreSpeed;
        restoredSpeed = unlockTarget;
        events.add(
          SpeedUnlockedEvent(restoreSpeed: unlockTarget, reason: reason),
        );
      }
    }

    final hadActiveWork = _state != TouchGestureState.idle &&
        _state != TouchGestureState.lockedIdle;
    if (hadActiveWork || restoredSpeed != null) {
      _state = TouchGestureState.cancelled;
      events.add(
        GestureCancelledEvent(reason: reason, restoredSpeed: restoredSpeed),
      );
    }

    if (reason == GestureInterruptReason.screenLock) {
      _screenLocked = true;
      _state = TouchGestureState.lockedIdle;
    } else {
      _state = _restingState;
    }

    return events;
  }

  /// Clears multi-touch pointer remnants once all fingers lift.
  void onPointerCancelOrRemoved(int pointerId) {
    _activePointers.remove(pointerId);
  }

  List<TouchGestureEvent> _enterLongPressSpeed() {
    _state = TouchGestureState.longPressSpeed;
    _speedAnchorX = _currentX;
    _speedAnchorY = _currentY;
    final detents = config.speedDetents.isEmpty
        ? const <double>[1.25, 1.5, 2.0, 3.0]
        : config.speedDetents;
    // Per spec §3.1: default initial boost is 2.0x; if userNormalSpeed is
    // already 2.0x, auto-escalate to 3.0x.
    final preferred =
        (_preBoostNormalSpeed - config.defaultBoostSpeed).abs() < 0.01
            ? detents.last
            : config.defaultBoostSpeed;
    var bestIdx = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < detents.length; i++) {
      final diff = (detents[i] - preferred).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestIdx = i;
      }
    }
    _anchorDetentIndex = bestIdx;
    _currentDetentIndex = bestIdx;
    _activeBoostSpeed = detents[bestIdx];
    return <TouchGestureEvent>[
      SpeedBoostStartEvent(
        speed: _activeBoostSpeed,
        detentIndex: bestIdx,
        detents: detents,
        haptic: true,
      ),
    ];
  }

  int _sideStepSeconds(TapZone zone) {
    final sec = config.sideSeekSeconds;
    if (sec <= 0) return 0;
    if (zone == TapZone.left) return -sec;
    if (zone == TapZone.right) return sec;
    return 0;
  }

  List<TouchGestureEvent> _executeDiscreteDoubleTapAction(String action) {
    return switch (action) {
      'play_pause' => const <TouchGestureEvent>[TogglePlayPauseEvent()],
      'fullscreen' => const <TouchGestureEvent>[ToggleFullscreenEvent()],
      _ => const <TouchGestureEvent>[],
    };
  }

  int _computeHorizontalSeekPreview(double dx) {
    final width = _viewportWidth.clamp(200.0, 4000.0);
    final ratio = (dx.abs() / width).clamp(0.0, 1.0);
    final speedScale = 0.55 + 1.35 * ratio;
    final spanMs = (_durationMs / 5.0).clamp(60000.0, 300000.0);
    final deltaMs = (dx / width) * spanMs * speedScale;
    return (_startPositionMs + deltaMs).round().clamp(0, _durationMs);
  }

  double _computeVerticalValue(
    double startValue,
    double dyDownward,
    double minVal,
    double maxVal,
  ) {
    final height = _viewportHeight.clamp(220.0, 2000.0);
    final delta = -dyDownward / (height * 0.72);
    return (startValue + delta).clamp(minVal, maxVal);
  }
}

/// States for the desktop keyboard & TV remote left/right seek disambiguation FSM.
enum KeySeekState {
  keyIdle,
  holdSeekPending,
  keyFastForwardScrub,
  keyCancelled,
}

/// Pure-logic preview snapshot from [DesktopKeySeekStateMachine].
class KeySeekPreview {
  final KeySeekState state;
  final int direction;
  final int targetMs;
  final int deltaMs;
  final double speedSecPerSec;
  final bool isHoldPreview;

  const KeySeekPreview({
    required this.state,
    required this.direction,
    required this.targetMs,
    required this.deltaMs,
    required this.speedSecPerSec,
    required this.isHoldPreview,
  });
}

/// Desktop keyboard arrow seek disambiguation state machine aligned with
/// `player-hud-spec.md §2.2 & §3.3` and `TvRemoteSeekController`:
/// - Short tap (`< 280ms` on desktop, `< 500ms` on TV): commits `±15s` on key up.
/// - Hold (`>= 280ms`): smoothly integrates accelerated preview position without
///   calling decoder `seekTo`; commits a single seek on key up.
/// - `Escape`, focus loss, background, dialog, or episode switch cancels preview
///   without committing any seek.
class DesktopKeySeekStateMachine {
  static const int tapStepMs = 15000;
  static const int desktopHoldThresholdMs = 280;
  static const int tvHoldThresholdMs = 500;
  static const double initialSpeedSecPerSec = 30.0;
  static const double accelSecPerSec2 = 30.0;
  static const double maxSpeedSecPerSec = 240.0;

  /// Desktop `S` shortcut common speed cycle (`1.0 -> 1.25 -> 1.5 -> 2.0 -> 1.0`).
  static const List<double> desktopCycleSpeeds = <double>[
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  final int holdThresholdMs;

  KeySeekState _state = KeySeekState.keyIdle;
  int _direction = 0; // -1 rewind, +1 forward, 0 idle
  int _pressStartMs = 0;
  int _anchorPositionMs = 0;
  int _durationMs = 0;
  int _previewTargetMs = 0;

  DesktopKeySeekStateMachine({this.holdThresholdMs = desktopHoldThresholdMs});

  KeySeekState get state => _state;
  bool get isActive =>
      _state == KeySeekState.holdSeekPending ||
      _state == KeySeekState.keyFastForwardScrub;
  bool get isScrubbing => _state == KeySeekState.keyFastForwardScrub;
  int get direction => _direction;
  int get previewTargetMs => _previewTargetMs;

  /// Returns the next speed in the desktop `S` shortcut cycle.
  static double cycleDesktopSpeed(double currentSpeed) {
    for (var i = 0; i < desktopCycleSpeeds.length; i++) {
      if ((currentSpeed - desktopCycleSpeeds[i]).abs() < 0.02) {
        return desktopCycleSpeeds[(i + 1) % desktopCycleSpeeds.length];
      }
    }
    return desktopCycleSpeeds.first;
  }

  static double previewSpeedAt(double heldAfterThresholdSec) {
    if (heldAfterThresholdSec < 0) return 0;
    return (initialSpeedSecPerSec + accelSecPerSec2 * heldAfterThresholdSec)
        .clamp(initialSpeedSecPerSec, maxSpeedSecPerSec);
  }

  static double integratedOffsetSeconds(double heldAfterThresholdSec) {
    if (heldAfterThresholdSec <= 0) return 15.0;
    const capTimeSec =
        (maxSpeedSecPerSec - initialSpeedSecPerSec) / accelSecPerSec2;
    final accelPhase = math.min(heldAfterThresholdSec, capTimeSec);
    final distanceAccel = initialSpeedSecPerSec * accelPhase +
        0.5 * accelSecPerSec2 * accelPhase * accelPhase;
    final cappedPhase = math.max(0.0, heldAfterThresholdSec - capTimeSec);
    final distanceCapped = maxSpeedSecPerSec * cappedPhase;
    return 15.0 + distanceAccel + distanceCapped;
  }

  KeySeekPreview onKeyDownOrRepeat({
    required int direction,
    required int currentPositionMs,
    required int durationMs,
    required int nowMs,
  }) {
    assert(direction == -1 || direction == 1);
    if (isActive && _direction == direction) {
      return updatePreview(nowMs);
    }
    if (isActive && _direction != direction) {
      // Opposite arrow key pressed during scrub cancels previous preview first
      // per spec §2.2, then starts fresh in the new direction.
      cancel();
    }
    _direction = direction;
    _pressStartMs = nowMs;
    _durationMs = math.max(0, durationMs);
    _anchorPositionMs = _clampTarget(currentPositionMs);
    _previewTargetMs = _clampTarget(_anchorPositionMs + direction * tapStepMs);
    _state = KeySeekState.holdSeekPending;
    return KeySeekPreview(
      state: _state,
      direction: _direction,
      targetMs: _previewTargetMs,
      deltaMs: _previewTargetMs - _anchorPositionMs,
      speedSecPerSec: 0,
      isHoldPreview: false,
    );
  }

  KeySeekPreview updatePreview(int nowMs) {
    if (!isActive || _direction == 0) {
      return KeySeekPreview(
        state: _state,
        direction: 0,
        targetMs: _previewTargetMs,
        deltaMs: 0,
        speedSecPerSec: 0,
        isHoldPreview: false,
      );
    }
    final elapsedMs = math.max(0, nowMs - _pressStartMs);
    if (elapsedMs < holdThresholdMs) {
      _state = KeySeekState.holdSeekPending;
      _previewTargetMs =
          _clampTarget(_anchorPositionMs + _direction * tapStepMs);
      return KeySeekPreview(
        state: _state,
        direction: _direction,
        targetMs: _previewTargetMs,
        deltaMs: _previewTargetMs - _anchorPositionMs,
        speedSecPerSec: 0,
        isHoldPreview: false,
      );
    }
    _state = KeySeekState.keyFastForwardScrub;
    final heldSec = (elapsedMs - holdThresholdMs) / 1000.0;
    final offsetMs = (integratedOffsetSeconds(heldSec) * 1000.0).round();
    final speed = previewSpeedAt(heldSec);
    _previewTargetMs = _clampTarget(_anchorPositionMs + _direction * offsetMs);
    return KeySeekPreview(
      state: _state,
      direction: _direction,
      targetMs: _previewTargetMs,
      deltaMs: _previewTargetMs - _anchorPositionMs,
      speedSecPerSec: speed,
      isHoldPreview: true,
    );
  }

  /// Commits on key release and returns the target position in ms (or `null` if
  /// no arrow seek was active or duration is invalid).
  int? onKeyUp(int nowMs) {
    if (!isActive || _direction == 0) return null;
    final preview = updatePreview(nowMs);
    _direction = 0;
    _pressStartMs = 0;
    _state = KeySeekState.keyIdle;
    return _durationMs > 0 ? preview.targetMs : null;
  }

  /// Cancels an active seek without committing. Returns `true` if a preview
  /// was active (so `Escape` consumes the key instead of exiting fullscreen).
  bool cancel() {
    if (!isActive) return false;
    _state = KeySeekState.keyCancelled;
    _direction = 0;
    _pressStartMs = 0;
    _previewTargetMs = _anchorPositionMs;
    _state = KeySeekState.keyIdle;
    return true;
  }

  int _clampTarget(int rawMs) {
    if (_durationMs <= 0) return math.max(0, rawMs);
    return rawMs.clamp(0, _durationMs);
  }
}

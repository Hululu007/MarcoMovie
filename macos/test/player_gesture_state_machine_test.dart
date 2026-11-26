// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/player/gesture_state_machine.dart';

TouchPointerContext _ctx({
  int pointerId = 1,
  double x = 420,
  double y = 200,
  double width = 844,
  double height = 390,
  int nowMs = 1000,
  double insetLeft = 0,
  double insetRight = 0,
  double insetTop = 0,
  double insetBottom = 0,
  bool screenLocked = false,
  bool isLive = false,
  bool isPipOrMini = false,
  bool playing = true,
  int durationMs = 1200000,
  int positionMs = 120000,
  double userNormalSpeed = 1.0,
  double brightness = 0.8,
  double volume = 0.6,
  bool startedInsideDock = false,
  bool dialogOpen = false,
  bool isTouchPointer = true,
}) {
  return TouchPointerContext(
    pointerId: pointerId,
    x: x,
    y: y,
    viewportWidth: width,
    viewportHeight: height,
    nowMs: nowMs,
    systemGestureInsetLeft: insetLeft,
    systemGestureInsetRight: insetRight,
    systemInsetTop: insetTop,
    systemInsetBottom: insetBottom,
    screenLocked: screenLocked,
    isLive: isLive,
    isPipOrMini: isPipOrMini,
    playing: playing,
    durationMs: durationMs,
    positionMs: positionMs,
    userNormalSpeed: userNormalSpeed,
    brightness: brightness,
    volume: volume,
    startedInsideDock: startedInsideDock,
    dialogOpen: dialogOpen,
    isTouchPointer: isTouchPointer,
  );
}

void main() {
  group('PlayerGestureStateMachine — taps, double-taps, and multi-tap seek', () {
    test('single tap waits 260ms then emits ToggleControlsEvent', () {
      final fsm = PlayerGestureStateMachine();
      expect(fsm.onPointerDown(_ctx(nowMs: 1000)), isEmpty);
      expect(fsm.state, TouchGestureState.downPending);

      expect(
        fsm.onPointerUp(pointerId: 1, x: 420, y: 200, nowMs: 1080),
        isEmpty,
      );
      expect(fsm.state, TouchGestureState.waitDoubleTap);
      expect(fsm.nextTimerDeadlineMs, 1080 + 260);

      // Before deadline -> no event.
      expect(fsm.onTick(1339), isEmpty);
      expect(fsm.state, TouchGestureState.waitDoubleTap);

      // At deadline -> single tap settled.
      final events = fsm.onTick(1340);
      expect(events, hasLength(1));
      expect(events.single, isA<ToggleControlsEvent>());
      expect(fsm.state, TouchGestureState.idle);
    });

    test('center double tap triggers TogglePlayPause strictly on second UP', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 420, y: 200, nowMs: 1050);
      expect(fsm.state, TouchGestureState.waitDoubleTap);

      // Second down inside 260ms and 42dp slop must NOT fire yet.
      final down2 = fsm.onPointerDown(_ctx(x: 430, y: 205, nowMs: 1180));
      expect(down2, isEmpty);
      expect(fsm.state, TouchGestureState.secondTapDown);

      // Second UP fires TogglePlayPauseEvent.
      final up2 = fsm.onPointerUp(pointerId: 1, x: 430, y: 205, nowMs: 1230);
      expect(up2, hasLength(1));
      expect(up2.single, isA<TogglePlayPauseEvent>());
      expect(fsm.state, TouchGestureState.idle);
    });

    test('second tap beyond 42dp settles first single tap then starts new press', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 200, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 200, y: 200, nowMs: 1050);

      final down2 = fsm.onPointerDown(_ctx(x: 600, y: 200, nowMs: 1120));
      expect(down2, hasLength(1));
      expect(down2.single, isA<ToggleControlsEvent>());
      expect(fsm.state, TouchGestureState.downPending);
    });

    test('side double-tap enters 650ms multi-tap seek window and accumulates without toggling controls', () {
      final fsm = PlayerGestureStateMachine(
        config: const TouchGestureConfig(doubleTapSidesAction: 'seek_10s'),
      );
      // Right side double tap (x = 740 / 844 > 0.72)
      expect(fsm.config.leftZoneRatio, 0.28);
      expect(fsm.config.rightZoneRatio, 0.72);
      fsm.onPointerDown(_ctx(x: 740, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 740, y: 200, nowMs: 1040);
      fsm.onPointerDown(_ctx(x: 745, y: 202, nowMs: 1150));
      final up2 = fsm.onPointerUp(pointerId: 1, x: 745, y: 202, nowMs: 1200);
      expect(up2, hasLength(1));
      final seek1 = up2.single as DoubleTapSeekEvent;
      expect(seek1.deltaSec, 10);
      expect(seek1.totalAccumulatedSec, 10);
      expect(seek1.side, TapZone.right);
      expect(fsm.state, TouchGestureState.multiTapSeekWindow);

      // 3rd tap (odd tap!) within 650ms -> accumulates +20s and NEVER toggles controls
      fsm.onPointerDown(_ctx(x: 750, y: 200, nowMs: 1500));
      final up3 = fsm.onPointerUp(pointerId: 1, x: 750, y: 200, nowMs: 1540);
      expect(up3, hasLength(1));
      final seek2 = up3.single as DoubleTapSeekEvent;
      expect(seek2.deltaSec, 10);
      expect(seek2.totalAccumulatedSec, 20);
      expect(fsm.state, TouchGestureState.multiTapSeekWindow);

      // Window expires after 650ms -> emits MultiTapSeekEndEvent, NO ToggleControlsEvent
      final endEvents = fsm.onTick(1540 + 650);
      expect(endEvents, hasLength(1));
      expect((endEvents.single as MultiTapSeekEndEvent).totalAccumulatedSec, 20);
      expect(fsm.state, TouchGestureState.idle);
    });

    test('tapping opposite side during multi-tap window ends window without toggling controls', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 100, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 100, y: 200, nowMs: 1040);
      fsm.onPointerDown(_ctx(x: 105, y: 200, nowMs: 1140));
      final up2 = fsm.onPointerUp(pointerId: 1, x: 105, y: 200, nowMs: 1180);
      expect((up2.single as DoubleTapSeekEvent).deltaSec, -10);

      final opposite = fsm.onPointerDown(_ctx(x: 720, y: 200, nowMs: 1400));
      expect(opposite.any((e) => e is ToggleControlsEvent), isFalse);
      expect(opposite.any((e) => e is MultiTapSeekEndEvent), isTrue);
      expect(fsm.state, TouchGestureState.idle);
    });

    test('toggleable double-tap sides = play_pause disables side seek', () {
      final fsm = PlayerGestureStateMachine(
        config: const TouchGestureConfig(doubleTapSidesAction: 'play_pause'),
      );
      fsm.onPointerDown(_ctx(x: 100, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 100, y: 200, nowMs: 1040);
      fsm.onPointerDown(_ctx(x: 100, y: 200, nowMs: 1140));
      final up2 = fsm.onPointerUp(pointerId: 1, x: 100, y: 200, nowMs: 1180);
      expect(up2.single, isA<TogglePlayPauseEvent>());
      expect(fsm.state, TouchGestureState.idle);
    });

    test('second tap followed by horizontal drag enters horizontalSeek instead of double-tap', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 200, nowMs: 1000));
      fsm.onPointerUp(pointerId: 1, x: 420, y: 200, nowMs: 1050);
      fsm.onPointerDown(_ctx(x: 420, y: 200, nowMs: 1150));
      expect(fsm.state, TouchGestureState.secondTapDown);

      final move = fsm.onPointerMove(pointerId: 1, x: 460, y: 202, nowMs: 1180);
      expect(fsm.state, TouchGestureState.horizontalSeek);
      expect(move.any((e) => e is HorizontalSeekStartEvent), isTrue);
      expect(move.any((e) => e is HorizontalSeekUpdateEvent), isTrue);

      final commit = fsm.onPointerUp(pointerId: 1, x: 460, y: 202, nowMs: 1220);
      expect(commit.single, isA<HorizontalSeekCommitEvent>());
      expect(fsm.state, TouchGestureState.idle);
    });
  });

  group('PlayerGestureStateMachine — long-press speed boost, horizontal detents & swipe-up lock', () {
    test('stationary hold >= 350ms activates 2.0x boost; release restores previous speed', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 1.25));
      expect(fsm.nextTimerDeadlineMs, 1350);

      expect(fsm.onTick(1349), isEmpty);
      expect(fsm.state, TouchGestureState.downPending);

      final startEvents = fsm.onTick(1350);
      expect(fsm.state, TouchGestureState.longPressSpeed);
      final started = startEvents.single as SpeedBoostStartEvent;
      expect(started.speed, 2.0);
      expect(started.detentIndex, 2);
      expect(started.haptic, isTrue);

      final endEvents = fsm.onPointerUp(pointerId: 1, x: 420, y: 220, nowMs: 1900);
      expect((endEvents.single as SpeedBoostEndEvent).restoreSpeed, 1.25);
      expect(fsm.state, TouchGestureState.idle);
      expect(fsm.isSpeedLocked, isFalse);
    });

    test('when userNormalSpeed is already 2.0x, long-press escalates to 3.0x', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 2.0));
      final started = fsm.onTick(1350).single as SpeedBoostStartEvent;
      expect(started.speed, 3.0);
      expect(started.detentIndex, 3);
    });

    test('restore mode 1.0x restores 1.0x regardless of pre-boost speed', () {
      final fsm = PlayerGestureStateMachine(
        config: const TouchGestureConfig(longPressRestoreMode: '1.0x'),
      );
      fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 1.5));
      fsm.onTick(1350);
      final end = fsm.onPointerUp(pointerId: 1, x: 420, y: 220, nowMs: 1700);
      expect((end.single as SpeedBoostEndEvent).restoreSpeed, 1.0);
    });

    test('horizontal slide steps across 1.25x / 1.5x / 2.0x / 3.0x with haptics every 36dp', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000));
      fsm.onTick(1350); // anchor at x=420, detent=2 (2.0x)

      // Slide right +36dp -> 3.0x
      final to3x = fsm.onPointerMove(pointerId: 1, x: 456, y: 220, nowMs: 1400);
      expect((to3x.single as SpeedBoostChangeEvent).speed, 3.0);
      expect((to3x.single as SpeedBoostChangeEvent).haptic, isTrue);

      // Slide left -36dp from anchor -> 1.5x
      final to15x = fsm.onPointerMove(pointerId: 1, x: 384, y: 220, nowMs: 1450);
      expect((to15x.single as SpeedBoostChangeEvent).speed, 1.5);

      // Slide left -72dp from anchor -> 1.25x
      final to125x = fsm.onPointerMove(pointerId: 1, x: 348, y: 220, nowMs: 1500);
      expect((to125x.single as SpeedBoostChangeEvent).speed, 1.25);

      // Clamped at lowest detent (-120dp stays 1.25x, no redundant event)
      expect(fsm.onPointerMove(pointerId: 1, x: 300, y: 220, nowMs: 1550), isEmpty);
    });

    test('swipe up <= -48dp enters speedLockReady, hysteresis at -36dp, release locks and unlock restores', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 1.25));
      fsm.onTick(1350); // anchorY = 220

      // Slide up -48dp -> speedLockReady
      final readyEvents = fsm.onPointerMove(pointerId: 1, x: 420, y: 172, nowMs: 1420);
      expect(fsm.state, TouchGestureState.speedLockReady);
      expect((readyEvents.single as SpeedLockReadyChangedEvent).lockReady, isTrue);

      // Slight downward drift to -40dp stays in speedLockReady (hysteresis!)
      expect(fsm.onPointerMove(pointerId: 1, x: 420, y: 180, nowMs: 1440), isEmpty);
      expect(fsm.state, TouchGestureState.speedLockReady);

      // Drop below hysteresis (-35dp > -36dp) -> returns to longPressSpeed
      final cancelReady = fsm.onPointerMove(pointerId: 1, x: 420, y: 185, nowMs: 1460);
      expect(fsm.state, TouchGestureState.longPressSpeed);
      expect((cancelReady.single as SpeedLockReadyChangedEvent).lockReady, isFalse);

      // Swipe back up to -52dp and slide right to 3.0x, then release -> speedLocked @ 3.0x
      fsm.onPointerMove(pointerId: 1, x: 460, y: 168, nowMs: 1500);
      expect(fsm.state, TouchGestureState.speedLockReady);
      final lockEvents = fsm.onPointerUp(pointerId: 1, x: 460, y: 168, nowMs: 1550);
      expect(fsm.state, TouchGestureState.speedLocked);
      expect(fsm.isSpeedLocked, isTrue);
      expect((lockEvents.single as SpeedLockedEvent).speed, 3.0);

      // Tap unlock capsule -> restores pre-boost userNormalSpeed (1.25x)
      final unlockEvents = fsm.unlockSpeed();
      expect((unlockEvents.single as SpeedUnlockedEvent).restoreSpeed, 1.25);
      expect(fsm.isSpeedLocked, isFalse);
      expect(fsm.state, TouchGestureState.idle);
    });

    test('all interruption events during longPressSpeed, speedLockReady, and speedLocked guarantee speed restoration', () {
      const interruptReasons = <GestureInterruptReason>[
        GestureInterruptReason.pointerCancel,
        GestureInterruptReason.multiTouch,
        GestureInterruptReason.focusLost,
        GestureInterruptReason.lifecyclePause,
        GestureInterruptReason.audioFocusLost,
        GestureInterruptReason.pipEntered,
        GestureInterruptReason.dialogOpened,
        GestureInterruptReason.episodeSwitch,
        GestureInterruptReason.screenLock,
        GestureInterruptReason.backExit,
      ];

      for (final reason in interruptReasons) {
        final fsm = PlayerGestureStateMachine();
        fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 1.5));
        fsm.onTick(1350);
        // Move into speedLockReady
        fsm.onPointerMove(pointerId: 1, x: 420, y: 165, nowMs: 1420);
        expect(fsm.state, TouchGestureState.speedLockReady);

        final events = fsm.cancel(reason);
        expect(
          events.whereType<SpeedBoostEndEvent>().single.restoreSpeed,
          1.5,
          reason: 'Speed must restore on $reason during speedLockReady',
        );
        expect(fsm.isSpeedLocked, isFalse,
            reason: 'Must never lock speed on $reason');
        expect(
          fsm.state,
          reason == GestureInterruptReason.screenLock
              ? TouchGestureState.lockedIdle
              : TouchGestureState.idle,
        );
      }

      // Also verify auto-unlock on episodeSwitch / backExit / lifecyclePause / screenLock / multiTouch while speedLocked
      for (final unlockReason in const <GestureInterruptReason>[
        GestureInterruptReason.episodeSwitch,
        GestureInterruptReason.backExit,
        GestureInterruptReason.lifecyclePause,
        GestureInterruptReason.screenLock,
        GestureInterruptReason.multiTouch,
      ]) {
        final fsm = PlayerGestureStateMachine();
        fsm.onPointerDown(_ctx(x: 420, y: 220, nowMs: 1000, userNormalSpeed: 1.25));
        fsm.onTick(1350);
        fsm.onPointerMove(pointerId: 1, x: 420, y: 160, nowMs: 1400);
        fsm.onPointerUp(pointerId: 1, x: 420, y: 160, nowMs: 1450);
        expect(fsm.isSpeedLocked, isTrue);

        final events = fsm.cancel(unlockReason);
        expect(
          events.whereType<SpeedUnlockedEvent>().single.restoreSpeed,
          1.25,
          reason: 'Locked speed must auto-unlock on $unlockReason',
        );
        expect(fsm.isSpeedLocked, isFalse);
      }
    });
  });

  group('PlayerGestureStateMachine — guards, mutual exclusion & lock mode', () {
    test('edge back guard, vertical system guard, dock & PiP ignore touch', () {
      final fsm = PlayerGestureStateMachine();
      // Left edge < 24dp
      fsm.onPointerDown(_ctx(x: 18, y: 200, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);

      // Right edge respecting systemGestureInsetRight = 34dp
      fsm.onPointerDown(_ctx(x: 820, y: 200, width: 844, insetRight: 34, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);

      // Top/bottom vertical guard (< 28dp)
      fsm.onPointerDown(_ctx(x: 420, y: 20, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);
      fsm.onPointerDown(_ctx(x: 420, y: 370, height: 390, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);

      // Dock, PiP, dialogOpen
      fsm.onPointerDown(_ctx(startedInsideDock: true, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);
      fsm.onPointerDown(_ctx(isPipOrMini: true, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);
      fsm.onPointerDown(_ctx(dialogOpen: true, nowMs: 1000));
      expect(fsm.state, TouchGestureState.idle);
    });

    test('mutual exclusion: horizontal seek cancels pending long-press and discards preview on cancel', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 420, y: 200, nowMs: 1000));
      final moved = fsm.onPointerMove(pointerId: 1, x: 460, y: 202, nowMs: 1100);
      expect(fsm.state, TouchGestureState.horizontalSeek);
      expect(fsm.nextTimerDeadlineMs, isNull);
      expect(moved.any((e) => e is HorizontalSeekUpdateEvent), isTrue);

      // Long-press deadline passes -> MUST NOT trigger speed boost!
      expect(fsm.onTick(1600), isEmpty);
      expect(fsm.state, TouchGestureState.horizontalSeek);

      // Second finger interrupts -> cancels preview WITHOUT committing seek!
      final multi = fsm.onPointerDown(_ctx(pointerId: 2, x: 500, y: 200, nowMs: 1650));
      expect(multi.any((e) => e is HorizontalSeekCancelEvent), isTrue);
      expect(multi.any((e) => e is HorizontalSeekCommitEvent), isFalse);
      expect(fsm.state, TouchGestureState.idle);
    });

    test('vertical left drag adjusts brightness and right drag adjusts volume exclusively', () {
      final fsm = PlayerGestureStateMachine();
      fsm.onPointerDown(_ctx(x: 150, y: 220, nowMs: 1000, brightness: 0.5));
      final bEvents = fsm.onPointerMove(pointerId: 1, x: 152, y: 160, nowMs: 1080);
      expect(fsm.state, TouchGestureState.verticalBrightness);
      expect((bEvents.single as VerticalBrightnessUpdateEvent).brightness, greaterThan(0.5));
      fsm.onPointerUp(pointerId: 1, x: 152, y: 160, nowMs: 1150);

      fsm.onPointerDown(_ctx(x: 680, y: 220, nowMs: 2000, volume: 0.5));
      final vEvents = fsm.onPointerMove(pointerId: 1, x: 678, y: 160, nowMs: 2080);
      expect(fsm.state, TouchGestureState.verticalVolume);
      expect((vEvents.single as VerticalVolumeUpdateEvent).volume, greaterThan(0.5));
      fsm.onPointerUp(pointerId: 1, x: 678, y: 160, nowMs: 2150);
    });

    test('lockedIdle only toggles unlock capsule on single tap and blocks all other gestures', () {
      final fsm = PlayerGestureStateMachine();
      fsm.setScreenLocked(true);
      expect(fsm.state, TouchGestureState.lockedIdle);

      // Tap -> ToggleLockedControlsEvent
      fsm.onPointerDown(_ctx(screenLocked: true, nowMs: 1000));
      final up = fsm.onPointerUp(pointerId: 1, x: 420, y: 200, nowMs: 1060);
      expect(up.single, isA<ToggleLockedControlsEvent>());

      // Long press & drags -> completely blocked
      fsm.onPointerDown(_ctx(screenLocked: true, nowMs: 2000));
      expect(fsm.onTick(2600), isEmpty);
      expect(fsm.onPointerMove(pointerId: 1, x: 560, y: 200, nowMs: 2650), isEmpty);
      expect(fsm.onPointerUp(pointerId: 1, x: 560, y: 200, nowMs: 2700), isEmpty);
      expect(fsm.state, TouchGestureState.lockedIdle);
    });
  });

  group('DesktopKeySeekStateMachine', () {
    test('short press < 280ms commits +/-15s on key up', () {
      final keyFsm = DesktopKeySeekStateMachine();
      final p1 = keyFsm.onKeyDownOrRepeat(
        direction: 1,
        currentPositionMs: 60000,
        durationMs: 600000,
        nowMs: 1000,
      );
      expect(p1.state, KeySeekState.holdSeekPending);
      expect(p1.isHoldPreview, isFalse);

      final committed = keyFsm.onKeyUp(1180);
      expect(committed, 75000);
      expect(keyFsm.state, KeySeekState.keyIdle);
    });

    test('hold >= 280ms accelerates smoothly and Escape cancels without committing', () {
      final keyFsm = DesktopKeySeekStateMachine();
      keyFsm.onKeyDownOrRepeat(
        direction: 1,
        currentPositionMs: 60000,
        durationMs: 600000,
        nowMs: 1000,
      );
      final scrub = keyFsm.updatePreview(2280); // 1.0s past 280ms threshold
      expect(scrub.state, KeySeekState.keyFastForwardScrub);
      expect(scrub.isHoldPreview, isTrue);
      expect(scrub.speedSecPerSec, closeTo(60.0, 0.1));
      expect(scrub.targetMs, greaterThan(100000));

      // Cancel (Escape) returns true and discards preview
      expect(keyFsm.cancel(), isTrue);
      expect(keyFsm.state, KeySeekState.keyIdle);
      expect(keyFsm.onKeyUp(2400), isNull);
    });

    test('desktop S speed cycle rotates 1.0 -> 1.25 -> 1.5 -> 2.0 -> 1.0', () {
      expect(DesktopKeySeekStateMachine.cycleDesktopSpeed(1.0), 1.25);
      expect(DesktopKeySeekStateMachine.cycleDesktopSpeed(1.25), 1.5);
      expect(DesktopKeySeekStateMachine.cycleDesktopSpeed(1.5), 2.0);
      expect(DesktopKeySeekStateMachine.cycleDesktopSpeed(2.0), 1.0);
      expect(DesktopKeySeekStateMachine.cycleDesktopSpeed(0.75), 1.0);
    });

    test('S-07: KeyRepeatEvent after Escape cancel does NOT start a new seek session and mismatched KeyUp direction is ignored', () {
      final keyFsm = DesktopKeySeekStateMachine();
      keyFsm.onKeyDownOrRepeat(
        direction: 1,
        currentPositionMs: 120000,
        durationMs: 600000,
        nowMs: 1000,
        isRepeat: false,
      );
      keyFsm.updatePreview(1600);
      expect(keyFsm.isScrubbing, isTrue);

      // Escape cancels the hold-seek session.
      expect(keyFsm.cancel(), isTrue);
      expect(keyFsm.isActive, isFalse);

      // OS continues emitting KeyRepeatEvent while finger hasn't lifted yet.
      final repeatAfterEsc = keyFsm.onKeyDownOrRepeat(
        direction: 1,
        currentPositionMs: 120000,
        durationMs: 600000,
        nowMs: 1630,
        isRepeat: true,
      );
      expect(repeatAfterEsc.isHoldPreview, isFalse);
      expect(keyFsm.isActive, isFalse);
      expect(keyFsm.state, KeySeekState.keyIdle);
      expect(keyFsm.onKeyUp(1660, direction: 1), isNull);

      // Hold right, then press fresh left -> releasing right must NOT commit left.
      keyFsm.onKeyDownOrRepeat(
        direction: 1,
        currentPositionMs: 120000,
        durationMs: 600000,
        nowMs: 2000,
        isRepeat: false,
      );
      keyFsm.onKeyDownOrRepeat(
        direction: -1,
        currentPositionMs: 120000,
        durationMs: 600000,
        nowMs: 2100,
        isRepeat: false,
      );
      expect(keyFsm.direction, -1);
      expect(keyFsm.onKeyUp(2150, direction: 1), isNull);
      expect(keyFsm.isActive, isTrue);
      expect(keyFsm.direction, -1);

      // Releasing matching left key commits rewind (-15s).
      final committed = keyFsm.onKeyUp(2200, direction: -1);
      expect(committed, 105000);
      expect(keyFsm.isActive, isFalse);
    });
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Ordered cold-launch stage breadcrumb entry for diagnosing first-install
/// white-screen or startup-stall reports across iPadOS / iOS devices.
class MarcoLaunchBreadcrumb {
  final String stage;
  final String detail;
  final int elapsedMs;
  final DateTime timestamp;
  final int? attemptId;

  const MarcoLaunchBreadcrumb({
    required this.stage,
    required this.detail,
    required this.elapsedMs,
    required this.timestamp,
    this.attemptId,
  });

  @override
  String toString() =>
      '[MarcoLaunch] +${elapsedMs}ms stage=$stage'
      '${attemptId == null ? '' : ' attempt=$attemptId'}'
      '${detail.isEmpty ? '' : ' detail=$detail'}';
}

/// Async continuations retain the attempt that scheduled them, including after
/// its deadline when another initialization is already running.
class MarcoLaunchAttempt {
  MarcoLaunchAttempt._(this.id);

  final int id;
  String _workingStage = 'bootstrap_attempt';
  String get workingStage => _workingStage;

  Future<T> run<T>(Future<T> Function() task) =>
      runZoned(task, zoneValues: {MarcoLaunchAttempt: this});
}

/// Lightweight, zero-I/O startup timeline recorder following the exact audit
/// sequence:
/// 1. System launch screen (LaunchScreen.storyboard / LaunchImage)
/// 2. Native window & root controller (`MarcoFlutterViewController`)
/// 3. Flutter engine & plugin registration (`MarcoNativeChannelRegistrar`)
/// 4. Dart `main()`
/// 5. Flutter first frame (`MarcoBootstrapApp`)
/// 6. Local data initialization (`StorageService.init`)
/// 7. Home or first-launch onboarding interactive (`shell_interactive`)
class MarcoLaunchDiagnostics {
  MarcoLaunchDiagnostics._();

  static final Stopwatch _clock = Stopwatch()..start();
  static final List<MarcoLaunchBreadcrumb> _entries = <MarcoLaunchBreadcrumb>[];
  static MarcoLaunchAttempt? _activeAttempt;

  static const Set<String> _metaOutcomeStages = <String>{
    'bootstrap_timeout',
    'bootstrap_error',
    'bootstrap_ready',
  };

  /// Lifecycle / wrapper milestones that can fire asynchronously AFTER a
  /// bootstrap task has already started (e.g. `flutter_first_frame` arriving
  /// 3ms after `storage_init_start`). Prefer any real initialization stage
  /// over these when diagnosing where startup stalled.
  static const Set<String> _nonTaskLifecycleStages = <String>{
    'flutter_first_frame',
    'bootstrap_attempt',
  };

  static List<MarcoLaunchBreadcrumb> get entries =>
      List<MarcoLaunchBreadcrumb>.unmodifiable(_entries);

  static MarcoLaunchAttempt beginAttempt(int id) {
    final attempt = MarcoLaunchAttempt._(id);
    _activeAttempt = attempt;
    return attempt;
  }

  static void endAttempt(MarcoLaunchAttempt attempt) {
    if (identical(_activeAttempt, attempt)) _activeAttempt = null;
  }

  static void record(String stage, [String detail = '']) {
    if (!_clock.isRunning) _clock.start();
    final attempt = Zone.current[MarcoLaunchAttempt] as MarcoLaunchAttempt? ??
        _activeAttempt;
    if (attempt != null &&
        !_metaOutcomeStages.contains(stage) &&
        !_nonTaskLifecycleStages.contains(stage)) {
      attempt._workingStage = stage;
    }
    final entry = MarcoLaunchBreadcrumb(
      stage: stage,
      detail: detail,
      elapsedMs: _clock.elapsedMilliseconds,
      timestamp: DateTime.now(),
      attemptId: attempt?.id,
    );
    _entries.add(entry);
    if (_entries.length > 64) {
      _entries.removeAt(0);
    }
    debugPrint(entry.toString());
  }

  @visibleForTesting
  static void resetForTesting() {
    _activeAttempt = null;
    _entries.clear();
    _clock
      ..reset()
      ..start();
  }
}

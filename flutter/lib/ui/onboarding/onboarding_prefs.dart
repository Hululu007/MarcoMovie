// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/ohos_runtime.dart';

/// Device-local preference keys for onboarding and first-play gesture hint.
/// Intentionally kept outside cross-device sync/backup schemas.
class OnboardingPrefs {
  static const String doneVersionKey = 'onboarding_done_version';
  static const String playHintShownCountKey = 'play_hint_shown_count';
  static const String playHintDismissedKey = 'play_hint_dismissed';
  static const String officialChannelNoticeVersionKey =
      'official_channel_notice_version';

  static const int currentVersion = 1;
  static const int currentOfficialChannelNoticeVersion = 1;
  static const int maxPlayHintShows = 3;

  final SharedPreferences _prefs;

  const OnboardingPrefs(this._prefs);

  static Future<OnboardingPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return OnboardingPrefs(prefs);
  }

  int get doneVersion => _prefs.getInt(doneVersionKey) ?? 0;

  int get officialChannelNoticeVersion =>
      _prefs.getInt(officialChannelNoticeVersionKey) ?? 0;

  int get playHintShownCount => _prefs.getInt(playHintShownCountKey) ?? 0;

  bool get playHintDismissed => _prefs.getBool(playHintDismissedKey) ?? false;

  /// Returns `true` when the first-launch official channel & author anti-tamper
  /// notice has not yet been acknowledged on this device.
  bool shouldShowOfficialChannelNotice() {
    return officialChannelNoticeVersion < currentOfficialChannelNoticeVersion;
  }

  /// Persists acknowledgment of the first-launch official channel notice.
  /// Returns `true` ONLY when the underlying preference store confirms the
  /// write succeeded; on `false` or exception, reconciles the in-memory cache
  /// with the backing store so subsequent reads agree with persisted storage.
  Future<bool> markOfficialChannelNoticeSeen() async {
    try {
      final saved = await _prefs.setInt(
        officialChannelNoticeVersionKey,
        currentOfficialChannelNoticeVersion,
      );
      if (saved) return true;
    } catch (_) {
      // Fall through to cache reconciliation below.
    }
    try {
      await _prefs.reload();
    } catch (_) {
      // Reload also failed; never masquerade an unconfirmed write as persisted.
    }
    return false;
  }

  /// Returns `true` only when onboarding has not completed the current version
  /// and the device is NOT HarmonyOS NEXT (`!OhosRuntime.isOhos`).
  bool shouldShowOnboarding() {
    if (OhosRuntime.isOhos) return false;
    return doneVersion < currentVersion;
  }

  /// Returns `true` when first-play gesture hint is still under the 3-display
  /// cap, not permanently dismissed, and NOT running on HarmonyOS NEXT.
  bool shouldShowFirstPlayHint() {
    if (OhosRuntime.isOhos) return false;
    if (playHintDismissed) return false;
    return playHintShownCount < maxPlayHintShows;
  }

  Future<void> markOnboardingCompleted() async {
    await _prefs.setInt(doneVersionKey, currentVersion);
  }

  /// Increments the displayed count (capped at [maxPlayHintShows]).
  Future<int> recordFirstPlayHintShown() async {
    final next = (playHintShownCount + 1).clamp(0, maxPlayHintShows);
    await _prefs.setInt(playHintShownCountKey, next);
    return next;
  }

  /// Permanently suppresses automatic first-play gesture hints until replay.
  Future<void> dismissFirstPlayHintForever() async {
    await _prefs.setBool(playHintDismissedKey, true);
  }

  /// Resets onboarding and first-play hint counters when user triggers replay
  /// from Settings -> About & Help.
  Future<void> resetForReplay() async {
    await _prefs.setInt(doneVersionKey, 0);
    await _prefs.setInt(playHintShownCountKey, 0);
    await _prefs.setBool(playHintDismissedKey, false);
  }
}

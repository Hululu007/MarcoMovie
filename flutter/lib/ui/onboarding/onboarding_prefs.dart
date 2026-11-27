// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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
  static const String lastSeenAppVersionKey = 'marco_last_seen_app_version';

  static const int currentVersion = 1;
  static const int currentOfficialChannelNoticeVersion = 1;
  static const int maxPlayHintShows = 3;

  @visibleForTesting
  static bool debugEnablePostUpdateAutoPopInTest = false;

  final SharedPreferences _prefs;

  const OnboardingPrefs(this._prefs);

  static Future<OnboardingPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return OnboardingPrefs(prefs);
  }

  int get doneVersion => _prefs.getInt(doneVersionKey) ?? 0;

  int get officialChannelNoticeVersion =>
      _prefs.getInt(officialChannelNoticeVersionKey) ?? 0;

  String get lastSeenAppVersion =>
      (_prefs.getString(lastSeenAppVersionKey) ?? '').trim();

  int get playHintShownCount => _prefs.getInt(playHintShownCountKey) ?? 0;

  bool get playHintDismissed => _prefs.getBool(playHintDismissedKey) ?? false;

  /// Normalizes `version` and optional `buildNumber` into a canonical version
  /// token (`x.y.z` or `x.y.z+build`).
  static String normalizeVersionToken(
    String version, {
    String buildNumber = '',
  }) {
    final v = version.trim();
    if (!RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(v)) return '';
    if (v.contains('+')) return v;
    final b = buildNumber.trim();
    if (b.isNotEmpty && RegExp(r'^\d+$').hasMatch(b)) {
      return '$v+$b';
    }
    return v;
  }

  static String _baseSemver(String token) {
    final idx = token.indexOf('+');
    return idx >= 0 ? token.substring(0, idx) : token;
  }

  /// One-time migration for legacy bare semver tokens (e.g. `'0.7.10'` saved
  /// before `+build` tokens were introduced): upgrades the persisted token to
  /// the full `x.y.z+build` [currentVersion] when the base semver matches so a
  /// subsequent build-only upgrade (`0.7.10+104` -> `0.7.10+105`) reliably
  /// triggers the post-update notice.
  Future<bool> migrateLegacyBareVersionTokenIfNeeded(
    String currentVersion,
  ) async {
    final clean = currentVersion.trim();
    if (!clean.contains('+') ||
        !RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(clean)) {
      return false;
    }
    final seen = lastSeenAppVersion;
    if (seen.isEmpty || seen.contains('+')) return false;
    if (_baseSemver(seen) != _baseSemver(clean)) return false;
    return markPostUpdateNoticeSeen(clean);
  }

  /// Returns `true` when [currentVersion] is a valid semantic version (with or
  /// without `+build`) and the user has not yet seen the post-update safety &
  /// sponsorship notice for it.
  ///
  /// Passing [hasExistingUserData] = `true` ensures existing users upgrading
  /// from an older version where `officialChannelNoticeVersion` was never
  /// stamped (`0`) and `lastSeenAppVersion` was empty still receive the
  /// post-update popup on first launch after updating.
  bool shouldShowPostUpdateNotice(
    String currentVersion, {
    bool hasExistingUserData = false,
  }) {
    if (OhosRuntime.isOhos) return false;
    final clean = currentVersion.trim();
    if (!RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(clean)) return false;
    final seen = lastSeenAppVersion;
    if (seen.isNotEmpty) {
      if (seen == clean) return false;
      final seenBase = _baseSemver(seen);
      final cleanBase = _baseSemver(clean);
      // Compatibility when one side carries `+build` and the other is bare
      // semver (e.g. legacy stored `0.7.10` or unit tests querying `'0.7.10'`).
      // Call `migrateLegacyBareVersionTokenIfNeeded(clean)` on startup so a
      // subsequent build-only bump (`0.7.10+104` -> `0.7.10+105`) triggers.
      if (!seen.contains('+') || !clean.contains('+')) {
        if (seenBase == cleanBase) return false;
      }
      return true;
    }
    // When `seen` is empty:
    // - True fresh installs (`!hasExistingUserData` and
    //   `officialChannelNoticeVersion == 0` and `doneVersion == 0`) show the
    //   initial `OfficialChannelNoticeDialog` and stamp `lastSeenAppVersion`.
    // - Existing users upgrading from any earlier release (`hasExistingUserData`
    //   or `officialChannelNoticeVersion >= 1` or `doneVersion >= 1`) MUST see
    //   the post-update notice on first open after updating.
    final isUpgradedInstall =
        hasExistingUserData ||
        officialChannelNoticeVersion >= currentOfficialChannelNoticeVersion ||
        doneVersion >= OnboardingPrefs.currentVersion;
    return isUpgradedInstall;
  }

  /// Persists acknowledgment of the post-update notice for [version].
  Future<bool> markPostUpdateNoticeSeen(String version) async {
    final clean = version.trim();
    if (clean.isEmpty) return false;
    try {
      return await _prefs.setString(lastSeenAppVersionKey, clean);
    } catch (_) {
      return false;
    }
  }

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

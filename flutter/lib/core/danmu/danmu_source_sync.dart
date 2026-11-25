// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:math' as math;

import 'dandanplay_provider.dart';

/// One synced danmu server entry inside the sidecar WebDAV document
/// (e.g. `family.danmu.json`).
///
/// Security contract: NEVER stores `appId` or `appSecret`. Credentials remain
/// strictly local on each device; only [requiresAuth] hints that a newly
/// restored device should prompt the user to enter or associate local
/// credentials.
class DanmuSyncSourceEntry {
  final String url;
  final bool requiresAuth;

  const DanmuSyncSourceEntry({
    required this.url,
    this.requiresAuth = false,
  });

  DanmuSyncSourceEntry copyWith({
    String? url,
    bool? requiresAuth,
  }) {
    return DanmuSyncSourceEntry(
      url: url ?? this.url,
      requiresAuth: requiresAuth ?? this.requiresAuth,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'requiresAuth': requiresAuth,
      };

  static DanmuSyncSourceEntry? tryFromJson(dynamic raw) {
    if (raw is String) {
      final norm = DandanplayProvider.normalizeOriginOrNull(raw);
      if (norm == null) return null;
      return DanmuSyncSourceEntry(url: norm);
    }
    if (raw is Map) {
      final rawUrl = (raw['url'] ?? '').toString().trim();
      final norm = DandanplayProvider.normalizeOriginOrNull(rawUrl);
      if (norm == null) return null;
      return DanmuSyncSourceEntry(
        url: norm,
        requiresAuth: raw['requiresAuth'] == true,
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is DanmuSyncSourceEntry &&
      other.url == url &&
      other.requiresAuth == requiresAuth;

  @override
  int get hashCode => Object.hash(url, requiresAuth);
}

/// Sidecar WebDAV document for danmu server addresses and backup priority order.
class DanmuSourceSyncDocument {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final int updatedAt;
  final int revision;
  final int clearedAt;
  final bool initialized;
  final List<DanmuSyncSourceEntry> sources;

  const DanmuSourceSyncDocument({
    this.schemaVersion = currentSchemaVersion,
    this.updatedAt = 0,
    this.revision = 0,
    this.clearedAt = 0,
    this.initialized = false,
    this.sources = const <DanmuSyncSourceEntry>[],
  });

  List<String> get urls =>
      List<String>.unmodifiable(sources.map((s) => s.url));

  String toMultilineServerUrls() => urls.join('\n');

  bool get isFreshUninitialized =>
      !initialized && updatedAt <= 0 && revision <= 0 && sources.isEmpty;

  DanmuSourceSyncDocument copyWith({
    int? schemaVersion,
    int? updatedAt,
    int? revision,
    int? clearedAt,
    bool? initialized,
    List<DanmuSyncSourceEntry>? sources,
  }) {
    return DanmuSourceSyncDocument(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      revision: revision ?? this.revision,
      clearedAt: clearedAt ?? this.clearedAt,
      initialized: initialized ?? this.initialized,
      sources: sources ?? this.sources,
    );
  }

  static List<DanmuSyncSourceEntry> sanitizeEntries(
    Iterable<DanmuSyncSourceEntry> raw,
  ) {
    final out = <DanmuSyncSourceEntry>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (out.length >= DandanplayProvider.maxServers) break;
      final norm = DandanplayProvider.normalizeOriginOrNull(entry.url);
      if (norm == null || !seen.add(norm)) continue;
      out.add(DanmuSyncSourceEntry(url: norm, requiresAuth: entry.requiresAuth));
    }
    return List<DanmuSyncSourceEntry>.unmodifiable(out);
  }

  Map<String, dynamic> toPayloadMap() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'updatedAt': updatedAt,
        'revision': revision,
        'clearedAt': clearedAt,
        'sources': sources.map((e) => e.toJson()).toList(growable: false),
      };

  String toPayloadJson() => jsonEncode(toPayloadMap());

  Map<String, dynamic> toLocalSnapshotMap() => <String, dynamic>{
        ...toPayloadMap(),
        'initialized': initialized,
      };

  static DanmuSourceSyncDocument? tryParseJson(
    String? rawJson, {
    bool treatAsRemote = true,
  }) {
    final trimmed = (rawJson ?? '').trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;

      // Validate schemaVersion strictly: unknown or missing future versions
      // (e.g. schemaVersion: 2) must be rejected so we never misread them as
      // an empty source list and wipe local configuration.
      final rawSchema = decoded['schemaVersion'];
      if (rawSchema is! num || rawSchema.toInt() != currentSchemaVersion) {
        return null;
      }

      // Require `sources` to be explicitly present as a List; missing or
      // non-List `sources` is a malformed/incompatible document.
      if (!decoded.containsKey('sources') || decoded['sources'] is! List) {
        return null;
      }
      final rawSources = decoded['sources'] as List;
      final entries = <DanmuSyncSourceEntry>[];
      for (final item in rawSources) {
        final parsed = DanmuSyncSourceEntry.tryFromJson(item);
        if (parsed != null) entries.add(parsed);
      }
      if (rawSources.isNotEmpty && entries.isEmpty) {
        return null;
      }
      final updatedAt = (decoded['updatedAt'] as num?)?.toInt() ?? 0;
      final revision = (decoded['revision'] as num?)?.toInt() ?? 0;
      final clearedAt = (decoded['clearedAt'] as num?)?.toInt() ?? 0;
      final initialized = treatAsRemote
          ? true
          : (decoded['initialized'] == true ||
              updatedAt > 0 ||
              revision > 0 ||
              entries.isNotEmpty);
      return DanmuSourceSyncDocument(
        schemaVersion: currentSchemaVersion,
        updatedAt: math.max(0, updatedAt),
        revision: math.max(0, revision),
        clearedAt: math.max(0, clearedAt),
        initialized: initialized,
        sources: sanitizeEntries(entries),
      );
    } catch (_) {
      return null;
    }
  }
}

class DanmuSourceSyncMergeResult {
  final DanmuSourceSyncDocument merged;
  final bool localChanged;
  final bool needsUpload;
  final List<String> pendingAuthOrigins;

  const DanmuSourceSyncMergeResult({
    required this.merged,
    required this.localChanged,
    required this.needsUpload,
    required this.pendingAuthOrigins,
  });
}

/// Deterministic 3-way merger for WebDAV danmu source synchronization:
/// - Fresh device empty state (`!initialized && updatedAt == 0 && sources.isEmpty`)
///   restores remote sources without ever erasing them.
/// - Deliberate user clear (`clearedAt > 0 && initialized`) propagates empty
///   sources to peer devices.
/// - Supports add, delete, reorder, clear, and concurrent writes across two
///   profiles without silent lost updates.
class DanmuSourceSyncMerger {
  DanmuSourceSyncMerger._();

  static bool _sameSources(
    DanmuSourceSyncDocument a,
    DanmuSourceSyncDocument b,
  ) {
    if (a.sources.length != b.sources.length) return false;
    for (int i = 0; i < a.sources.length; i++) {
      if (a.sources[i] != b.sources[i]) return false;
    }
    return true;
  }

  static bool _sameUrls(
    DanmuSourceSyncDocument a,
    DanmuSourceSyncDocument b,
  ) {
    if (a.sources.length != b.sources.length) return false;
    for (int i = 0; i < a.sources.length; i++) {
      if (a.sources[i].url != b.sources[i].url) return false;
    }
    return true;
  }

  static bool _sameState(
    DanmuSourceSyncDocument a,
    DanmuSourceSyncDocument b,
  ) {
    return _sameSources(a, b) && a.clearedAt == b.clearedAt;
  }

  static List<String> _computePendingAuthOrigins(
    DanmuSourceSyncDocument doc,
    bool hasLocalCredentials, {
    Set<String>? authorizedCredentialOrigins,
  }) {
    if (authorizedCredentialOrigins != null) {
      return List<String>.unmodifiable(
        doc.sources
            .where((s) =>
                s.requiresAuth && !authorizedCredentialOrigins.contains(s.url))
            .map((s) => s.url),
      );
    }
    if (hasLocalCredentials) return const <String>[];
    return List<String>.unmodifiable(
      doc.sources.where((s) => s.requiresAuth).map((s) => s.url),
    );
  }

  static DanmuSourceSyncMergeResult merge({
    required DanmuSourceSyncDocument local,
    required DanmuSourceSyncDocument? base,
    required DanmuSourceSyncDocument? remote,
    required bool hasLocalCredentials,
    Set<String>? authorizedCredentialOrigins,
    required int nowMs,
  }) {
    // Case 1: Remote sidecar file does not exist yet (404).
    if (remote == null) {
      if (local.isFreshUninitialized) {
        return DanmuSourceSyncMergeResult(
          merged: local,
          localChanged: false,
          needsUpload: false,
          pendingAuthOrigins: const <String>[],
        );
      }
      final next = local.copyWith(
        initialized: true,
        updatedAt: local.updatedAt > 0 ? local.updatedAt : nowMs,
        revision: math.max(1, local.revision),
      );
      return DanmuSourceSyncMergeResult(
        merged: next,
        localChanged: false,
        needsUpload: true,
        pendingAuthOrigins: _computePendingAuthOrigins(
          next,
          hasLocalCredentials,
          authorizedCredentialOrigins: authorizedCredentialOrigins,
        ),
      );
    }

    // Case 2: Local is a fresh uninitialized device -> always restore remote.
    if (local.isFreshUninitialized) {
      final restored = remote.copyWith(initialized: true);
      return DanmuSourceSyncMergeResult(
        merged: restored,
        localChanged: restored.sources.isNotEmpty,
        needsUpload: false,
        pendingAuthOrigins: _computePendingAuthOrigins(
          restored,
          hasLocalCredentials,
          authorizedCredentialOrigins: authorizedCredentialOrigins,
        ),
      );
    }

    // Case 3: Local and Remote already have identical ordered sources & clear state.
    if (_sameState(local, remote)) {
      final converged = local.copyWith(
        initialized: true,
        updatedAt: math.max(local.updatedAt, remote.updatedAt),
        revision: math.max(local.revision, remote.revision),
      );
      return DanmuSourceSyncMergeResult(
        merged: converged,
        localChanged: false,
        needsUpload: false,
        pendingAuthOrigins: _computePendingAuthOrigins(
          converged,
          hasLocalCredentials,
          authorizedCredentialOrigins: authorizedCredentialOrigins,
        ),
      );
    }

    // Case 4: Fast-forward from Remote (local unchanged since last synced base).
    final localUnchanged = base != null && _sameState(local, base);
    final remoteUnchanged = base != null && _sameState(remote, base);
    if (localUnchanged && !remoteUnchanged) {
      final applied = remote.copyWith(initialized: true);
      return DanmuSourceSyncMergeResult(
        merged: applied,
        localChanged: !_sameUrls(local, applied) || !_sameSources(local, applied),
        needsUpload: false,
        pendingAuthOrigins: _computePendingAuthOrigins(
          applied,
          hasLocalCredentials,
          authorizedCredentialOrigins: authorizedCredentialOrigins,
        ),
      );
    }

    // Case 5: Fast-forward from Local (remote unchanged since last synced base).
    if (remoteUnchanged && !localUnchanged) {
      final nextUpdated = math.max(
        nowMs,
        math.max(local.updatedAt, remote.updatedAt) + 1,
      );
      final pushed = local.copyWith(
        initialized: true,
        updatedAt: nextUpdated,
        revision: math.max(local.revision, remote.revision) + 1,
      );
      return DanmuSourceSyncMergeResult(
        merged: pushed,
        localChanged: false,
        needsUpload: true,
        pendingAuthOrigins: _computePendingAuthOrigins(
          pushed,
          hasLocalCredentials,
          authorizedCredentialOrigins: authorizedCredentialOrigins,
        ),
      );
    }

    // Case 6: Both sides changed concurrently (or first merge without common base).
    // 6a. Explicit deliberate clear strictly newer than peer's last edit wins.
    if (local.sources.isEmpty &&
        local.clearedAt > 0 &&
        local.clearedAt > remote.updatedAt) {
      final pushed = local.copyWith(
        initialized: true,
        updatedAt: math.max(nowMs, math.max(local.updatedAt, remote.updatedAt) + 1),
        revision: math.max(local.revision, remote.revision) + 1,
      );
      return DanmuSourceSyncMergeResult(
        merged: pushed,
        localChanged: false,
        needsUpload: true,
        pendingAuthOrigins: const <String>[],
      );
    }
    if (remote.sources.isEmpty &&
        remote.clearedAt > 0 &&
        remote.clearedAt > local.updatedAt) {
      final applied = remote.copyWith(initialized: true);
      return DanmuSourceSyncMergeResult(
        merged: applied,
        localChanged: local.sources.isNotEmpty,
        needsUpload: false,
        pendingAuthOrigins: const <String>[],
      );
    }

    // 6b. Deterministic 3-way merge preserving ordering of newer side,
    // honoring deletions from `base`, and preserving concurrent additions from both.
    final baseUrls = base?.urls.toSet() ?? const <String>{};
    final localByUrl = <String, DanmuSyncSourceEntry>{
      for (final s in local.sources) s.url: s,
    };
    final remoteByUrl = <String, DanmuSyncSourceEntry>{
      for (final s in remote.sources) s.url: s,
    };
    final deletedByLocal = baseUrls.difference(localByUrl.keys.toSet());
    final deletedByRemote = baseUrls.difference(remoteByUrl.keys.toSet());
    final addedByLocal = localByUrl.keys.toSet().difference(baseUrls);
    final addedByRemote = remoteByUrl.keys.toSet().difference(baseUrls);

    final bool localIsPrimary;
    if (local.updatedAt != remote.updatedAt) {
      localIsPrimary = local.updatedAt > remote.updatedAt;
    } else if (local.revision != remote.revision) {
      localIsPrimary = local.revision > remote.revision;
    } else {
      localIsPrimary =
          local.toMultilineServerUrls().compareTo(remote.toMultilineServerUrls()) >=
              0;
    }

    final primary = localIsPrimary ? local : remote;
    final secondary = localIsPrimary ? remote : local;
    final deletedBySecondary =
        localIsPrimary ? deletedByRemote : deletedByLocal;
    final addedBySecondary = localIsPrimary ? addedByRemote : addedByLocal;

    final mergedEntries = <DanmuSyncSourceEntry>[];
    final seen = <String>{};

    void addUrl(String url) {
      if (mergedEntries.length >= DandanplayProvider.maxServers) return;
      if (!seen.add(url)) return;
      final reqAuth = (localByUrl[url]?.requiresAuth ?? false) ||
          (remoteByUrl[url]?.requiresAuth ?? false);
      mergedEntries.add(DanmuSyncSourceEntry(url: url, requiresAuth: reqAuth));
    }

    for (final entry in primary.sources) {
      if (deletedBySecondary.contains(entry.url)) continue;
      addUrl(entry.url);
    }
    for (final entry in secondary.sources) {
      if (addedBySecondary.contains(entry.url) ||
          !baseUrls.contains(entry.url)) {
        addUrl(entry.url);
      }
    }

    final mergedDoc = DanmuSourceSyncDocument(
      schemaVersion: DanmuSourceSyncDocument.currentSchemaVersion,
      updatedAt: math.max(nowMs, math.max(local.updatedAt, remote.updatedAt) + 1),
      revision: math.max(local.revision, remote.revision) + 1,
      clearedAt: mergedEntries.isEmpty ? nowMs : 0,
      initialized: true,
      sources: List<DanmuSyncSourceEntry>.unmodifiable(mergedEntries),
    );
    return DanmuSourceSyncMergeResult(
      merged: mergedDoc,
      localChanged: !_sameSources(local, mergedDoc),
      needsUpload: !_sameSources(remote, mergedDoc),
      pendingAuthOrigins: _computePendingAuthOrigins(
        mergedDoc,
        hasLocalCredentials,
        authorizedCredentialOrigins: authorizedCredentialOrigins,
      ),
    );
  }
}

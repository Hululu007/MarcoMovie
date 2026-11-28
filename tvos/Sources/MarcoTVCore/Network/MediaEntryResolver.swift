// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Outcome of resolving a Continue Watching / History / Favorite entry strictly against its original site.
public enum OriginSiteLookupResult: Equatable, Sendable {
    case available(CmsSite)
    case unavailable(siteKey: String, reason: String)
}

/// Complete detail + resume recovery outcome for Continue Watching, Watch History, and Favorites entries.
public enum MediaEntryResolutionResult: Equatable, Sendable {
    case ready(site: CmsSite, video: CmsVideo, resumeHistory: WatchHistoryItem?)
    case sourceUnavailable(siteKey: String, reason: String)
}

/// Resolves watch history & favorite cards strictly by their original `(siteKey, videoId)` identity,
/// enforces public-visible privacy filtering for ordinary surfaces & ambient backdrop posters, and
/// rejects ambiguous legacy bare site keys instead of guessing.
public enum MediaEntryResolver {

    // MARK: - Strict Origin Site Resolution (Order-Independent, Non-Guessing)

    public static func lookupOriginSite(siteKey: String, in config: CmsConfig) -> OriginSiteLookupResult {
        let cleanKey = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            return .unavailable(
                siteKey: cleanKey,
                reason: "该记录缺少原片源标识，已保留记录"
            )
        }

        let owners = config.effectiveSiteOwners

        // 1. Exact canonical key match (e.g. `sub::<subId>::<rawKey>` or unscoped standalone site key)
        if let exactOwner = owners.first(where: { $0.canonicalKey == cleanKey }) {
            return resolveOwner(exactOwner, requestedKey: cleanKey, in: config)
        }

        // 2. Legacy v0.1.1 disambiguated suffix match (`<rawKey>_<subscriptionId>`)
        if let legacyDisambigOwner = owners.first(where: {
            !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == cleanKey
        }) {
            return resolveOwner(legacyDisambigOwner, requestedKey: cleanKey, in: config)
        }

        // 3. Scoped key (`sub::<subId>::<rawKey>`) whose owning subscription is no longer present -> NEVER guess!
        if let parsed = CmsSite.parseScopedKey(cleanKey) {
            if config.privateSubscriptionIds.contains(parsed.subscriptionId)
                || config.knownPrivateSiteKeys.contains(cleanKey)
            {
                return .unavailable(
                    siteKey: cleanKey,
                    reason: "该内容属于私密订阅，当前普通模式下不可打开（记录已保留）"
                )
            }
            return .unavailable(
                siteKey: cleanKey,
                reason: "原片源「\(parsed.rawKey)」所属订阅已停用或移除，记录已保留，请先在「设置 -> 订阅与片源」恢复对应来源"
            )
        }

        // 4. Legacy bare key match (e.g. `cms` from v0.1.1 or cross-platform WebDAV sync)
        if config.knownPrivateSiteKeys.contains(cleanKey) {
            return .unavailable(
                siteKey: cleanKey,
                reason: "该内容属于私密订阅，当前普通模式下不可打开（记录已保留）"
            )
        }
        let rawMatches = owners.filter { $0.rawKey == cleanKey }
        if rawMatches.count > 1 {
            // Multiple subscriptions share the same bare site key -> refuse to guess!
            let labels = rawMatches
                .map { o in o.subscriptionName.isEmpty ? o.siteName : "\(o.siteName)（\(o.subscriptionName)）" }
                .prefix(3)
                .joined(separator: "、")
            return .unavailable(
                siteKey: cleanKey,
                reason: "旧记录来源「\(cleanKey)」存在多个重名片源（\(labels)），无法自动判断原属来源，记录已保留"
            )
        }
        if config.ambiguousLegacyRawKeys.contains(cleanKey) {
            return .unavailable(
                siteKey: cleanKey,
                reason: "旧记录来源「\(cleanKey)」曾对应多个重名片源，无法自动判断原属来源，记录已保留"
            )
        }
        if rawMatches.count == 1, let singleOwner = rawMatches.first {
            return resolveOwner(singleOwner, requestedKey: cleanKey, in: config)
        }

        // 5. Fallback if caller passed a private-sub legacy suffix whose rawContent wasn't parsed
        for privSubId in config.privateSubscriptionIds where !privSubId.isEmpty && cleanKey.hasSuffix("_\(privSubId)") {
            return .unavailable(
                siteKey: cleanKey,
                reason: "该内容属于私密订阅，当前普通模式下不可打开（记录已保留）"
            )
        }

        return .unavailable(
            siteKey: cleanKey,
            reason: "原片源（\(cleanKey)）已停用或移除，记录已保留，请先在「设置 -> 订阅与片源」恢复对应来源"
        )
    }

    private static func resolveOwner(
        _ owner: SiteOwnershipRecord,
        requestedKey: String,
        in config: CmsConfig
    ) -> OriginSiteLookupResult {
        if owner.isPrivate {
            return .unavailable(
                siteKey: requestedKey,
                reason: "该内容属于私密订阅，当前普通模式下不可打开（记录已保留）"
            )
        }
        if !owner.isEnabled {
            let subSuffix = owner.subscriptionName.isEmpty ? "" : "（订阅「\(owner.subscriptionName)」）"
            return .unavailable(
                siteKey: requestedKey,
                reason: "原片源「\(owner.siteName)」\(subSuffix)已停用，记录已保留，请先在「设置 -> 订阅与片源」恢复对应来源"
            )
        }
        if !owner.isSupported {
            return .unavailable(
                siteKey: requestedKey,
                reason: "原片源「\(owner.siteName)」暂不可用：\(owner.unsupportedReason)（记录已保留）"
            )
        }
        if let site = config.publicAvailableSites.first(where: { $0.key == owner.canonicalKey }) {
            return .available(site)
        }
        return .unavailable(
            siteKey: requestedKey,
            reason: "原片源「\(owner.siteName)」暂不可用，记录已保留，请先在「设置 -> 订阅与片源」恢复对应来源"
        )
    }

    public static func sourceDisplayName(siteKey: String, in config: CmsConfig) -> String {
        let cleanKey = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return "未知来源" }

        let owners = config.effectiveSiteOwners
        if let owner = owners.first(where: { $0.canonicalKey == cleanKey })
            ?? owners.first(where: { !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == cleanKey })
        {
            let hasDuplicateName = owners.filter { $0.siteName == owner.siteName }.count > 1
            let qualified = (hasDuplicateName && !owner.subscriptionName.isEmpty)
                ? "\(owner.siteName) · \(owner.subscriptionName)"
                : owner.siteName
            if !owner.isEnabled {
                return "来源已停用 · \(qualified)"
            }
            return qualified
        }

        if let parsed = CmsSite.parseScopedKey(cleanKey) {
            return "来源已停用 · \(parsed.rawKey)"
        }

        if config.ambiguousLegacyRawKeys.contains(cleanKey) {
            return "重名来源待确认 · \(cleanKey)"
        }
        let rawMatches = owners.filter { $0.rawKey == cleanKey }
        if rawMatches.count == 1, let single = rawMatches.first {
            return single.isEnabled ? single.siteName : "来源已停用 · \(single.siteName)"
        }
        if rawMatches.count > 1 {
            return "重名来源待确认 · \(cleanKey)"
        }
        return "来源已停用 · \(cleanKey)"
    }

    // MARK: - Public Scope Filtering (Fail-Closed Private Subscription Isolation)

    /// Filters watch history to entries positively confirmed to belong to a public source on this device
    /// (Discover Continue Watching, Library, ambient backdrop). Underlying records remain untouched in storage.
    public static func publicVisibleWatchHistory(
        _ items: [WatchHistoryItem],
        in config: CmsConfig
    ) -> [WatchHistoryItem] {
        items.filter { config.isPublicDisplayAllowed($0.site) }
    }

    /// Filters favorites to entries positively confirmed to belong to a public source on this device.
    public static func publicVisibleFavorites(
        _ items: [FavoriteItem],
        in config: CmsConfig
    ) -> [FavoriteItem] {
        items.filter { config.isPublicDisplayAllowed($0.site) }
    }

    /// Computes the ambient backdrop poster URL strictly from public-visible sources.
    /// Returns `""` when poster sync is disabled or when no public poster is available so private posters
    /// are never displayed or requested over the network.
    public static func resolvePublicBackdropPosterUrl(
        ambientPosterSync: Bool,
        publicDiscoverVideos: [CmsVideo],
        publicWatchHistory: [WatchHistoryItem],
        config: CmsConfig
    ) -> String {
        guard ambientPosterSync else { return "" }
        let safeHistory = publicVisibleWatchHistory(publicWatchHistory, in: config)
        if let histPoster = safeHistory.first(where: { !$0.poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.poster {
            return histPoster
        }
        if let discoverPoster = publicDiscoverVideos.first(where: { !$0.poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.poster {
            return discoverPoster
        }
        return ""
    }

    // MARK: - Site-Record Matching (Canonical + Unambiguous Legacy Compatibility)

    public static func recordSiteMatches(
        recordSiteKey: String,
        site: CmsSite,
        in config: CmsConfig
    ) -> Bool {
        let clean = recordSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if clean == site.key { return true }
        if !site.subscriptionId.isEmpty && clean == "\(site.rawKey)_\(site.subscriptionId)" {
            return true
        }
        if clean == site.rawKey {
            if config.ambiguousLegacyRawKeys.contains(clean) {
                return false
            }
            let owners = config.effectiveSiteOwners.filter { $0.rawKey == site.rawKey }
            return owners.count <= 1
        }
        return false
    }

    public static func matchingHistory(
        siteKey: String,
        videoId: String,
        in history: [WatchHistoryItem]
    ) -> WatchHistoryItem? {
        history.first { $0.site == siteKey && $0.id == videoId }
    }

    public static func matchingHistory(
        for site: CmsSite,
        videoId: String,
        in history: [WatchHistoryItem],
        config: CmsConfig
    ) -> WatchHistoryItem? {
        if let exact = history.first(where: { $0.site == site.key && $0.id == videoId }) {
            return exact
        }
        return history.first { $0.id == videoId && recordSiteMatches(recordSiteKey: $0.site, site: site, in: config) }
    }

    public static func matchingFavorite(
        for site: CmsSite,
        videoId: String,
        in favorites: [FavoriteItem],
        config: CmsConfig
    ) -> FavoriteItem? {
        if let exact = favorites.first(where: { $0.site == site.key && $0.id == videoId }) {
            return exact
        }
        return favorites.first { $0.id == videoId && recordSiteMatches(recordSiteKey: $0.site, site: site, in: config) }
    }

    // MARK: - Detail + Resume Recovery

    /// Resolves a Continue Watching or Watch History entry back to its original site, full detail/lines, and resume point.
    public static func resolveWatchHistoryEntry(
        _ item: WatchHistoryItem,
        config: CmsConfig,
        cmsClient: CmsClient
    ) async throws -> MediaEntryResolutionResult {
        switch lookupOriginSite(siteKey: item.site, in: config) {
        case .unavailable(let siteKey, let reason):
            return .sourceUnavailable(siteKey: siteKey, reason: reason)
        case .available(let site):
            let stub = CmsVideo(
                id: item.id,
                title: item.title,
                poster: item.poster,
                remarks: item.episode
            )
            let detailed = try await cmsClient.fetchDetail(site: site, video: stub)
            return .ready(site: site, video: detailed, resumeHistory: item)
        }
    }

    /// Resolves a Favorite entry back to its original site, full detail/lines, and any saved resume point on that exact site.
    public static func resolveFavoriteEntry(
        _ fav: FavoriteItem,
        config: CmsConfig,
        watchHistory: [WatchHistoryItem],
        cmsClient: CmsClient
    ) async throws -> MediaEntryResolutionResult {
        switch lookupOriginSite(siteKey: fav.site, in: config) {
        case .unavailable(let siteKey, let reason):
            return .sourceUnavailable(siteKey: siteKey, reason: reason)
        case .available(let site):
            let stub = CmsVideo(
                id: fav.id,
                title: fav.title,
                poster: fav.poster,
                remarks: fav.remarks
            )
            let detailed = try await cmsClient.fetchDetail(site: site, video: stub)
            let resume = matchingHistory(siteKey: fav.site, videoId: fav.id, in: watchHistory)
                ?? matchingHistory(for: site, videoId: fav.id, in: watchHistory, config: config)
            return .ready(site: site, video: detailed, resumeHistory: resume)
        }
    }
}

/// Shared public-scope reconciliation & in-flight request admission guard used by `AppViewModel`
/// (and verified directly by unit tests) to ensure:
/// 1. Live TV channels are cleared whenever the loaded live source turns private or is removed,
///    even if another public live source shifts into the exact same list index (`selectedLiveSourceIndex`).
/// 2. Slow in-flight Discover, Live TV, Search, and Detail requests whose source turned private
///    before completion are dropped without polluting UI state or triggering poster/backdrop loads.
public enum PublicCatalogScopeGuard {
    public struct LiveSelectionReconciliation: Equatable, Sendable {
        public let nextIndex: Int
        public let shouldClearLoadedGroups: Bool
        public let nextLoadedIdentity: String?

        public init(nextIndex: Int, shouldClearLoadedGroups: Bool, nextLoadedIdentity: String?) {
            self.nextIndex = nextIndex
            self.shouldClearLoadedGroups = shouldClearLoadedGroups
            self.nextLoadedIdentity = nextLoadedIdentity
        }
    }

    public static func liveSourceIdentity(_ source: LiveSource) -> String {
        let sub = source.subscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pluginApi = source.plugin?.api.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(sub)::\(url)::\(pluginApi)::\(name)"
    }

    public static func reconcileLiveSourceSelection(
        previousLoadedIdentity: String?,
        currentSelectedIndex: Int,
        publicLives: [LiveSource]
    ) -> LiveSelectionReconciliation {
        guard !publicLives.isEmpty else {
            return LiveSelectionReconciliation(
                nextIndex: 0,
                shouldClearLoadedGroups: true,
                nextLoadedIdentity: nil
            )
        }
        if let loadedId = previousLoadedIdentity, !loadedId.isEmpty {
            if let movedIdx = publicLives.firstIndex(where: { liveSourceIdentity($0) == loadedId }) {
                return LiveSelectionReconciliation(
                    nextIndex: movedIdx,
                    shouldClearLoadedGroups: false,
                    nextLoadedIdentity: loadedId
                )
            }
            // Previously loaded live source became private or removed, even if another public
            // live source now occupies the same index -> MUST purge stale channels!
            return LiveSelectionReconciliation(
                nextIndex: 0,
                shouldClearLoadedGroups: true,
                nextLoadedIdentity: nil
            )
        }
        let clamped = publicLives.indices.contains(currentSelectedIndex) ? currentSelectedIndex : 0
        return LiveSelectionReconciliation(
            nextIndex: clamped,
            shouldClearLoadedGroups: false,
            nextLoadedIdentity: nil
        )
    }

    public static func canAcceptDiscoverResponse(
        siteKey: String,
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        activeSiteKey: String?,
        config: CmsConfig
    ) -> Bool {
        guard requestEpoch == currentEpoch,
              activeSiteKey == siteKey,
              !config.isPrivateSiteKey(siteKey)
        else {
            return false
        }
        return config.publicAvailableSites.contains(where: { $0.key == siteKey })
    }

    public static func canAcceptLiveResponse(
        sourceIdentity: String,
        requestToken: UInt64,
        currentToken: UInt64,
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        config: CmsConfig
    ) -> Bool {
        guard requestToken == currentToken,
              requestEpoch == currentEpoch
        else {
            return false
        }
        return config.publicSupportedLives.contains(where: { liveSourceIdentity($0) == sourceIdentity })
    }

    public static func canAcceptSearchBatch(
        siteKey: String,
        requestToken: UInt64,
        currentToken: UInt64,
        requestEpoch: UInt64,
        currentEpoch: UInt64,
        config: CmsConfig
    ) -> Bool {
        guard requestToken == currentToken,
              requestEpoch == currentEpoch,
              !config.isPrivateSiteKey(siteKey)
        else {
            return false
        }
        return config.publicAvailableSites.contains(where: { $0.key == siteKey })
    }
}

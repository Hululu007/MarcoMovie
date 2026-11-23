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

/// Resolves watch history & favorite cards strictly by their original `(siteKey, videoId)` identity.
/// Never falls back to `activeSite` when the original site is disabled or removed, preventing cross-site
/// ID collisions (e.g. two sites both having video ID `42`) from opening the wrong title.
public enum MediaEntryResolver {
    public static func lookupOriginSite(siteKey: String, in config: CmsConfig) -> OriginSiteLookupResult {
        let cleanKey = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            return .unavailable(
                siteKey: cleanKey,
                reason: "该记录缺少原片源标识，已保留记录"
            )
        }
        if let site = config.publicAvailableSites.first(where: { $0.key == cleanKey }) {
            return .available(site)
        }
        if let publicUnsupported = config.sites.first(where: { $0.key == cleanKey && !$0.isEffectivelyPrivate }) {
            return .unavailable(
                siteKey: cleanKey,
                reason: "原片源「\(publicUnsupported.name)」暂不可用：\(publicUnsupported.unsupportedReason)（记录已保留）"
            )
        }
        return .unavailable(
            siteKey: cleanKey,
            reason: "原片源（\(cleanKey)）已停用或移除，记录已保留，请先在「设置 -> 订阅与片源」恢复对应来源"
        )
    }

    public static func sourceDisplayName(siteKey: String, in config: CmsConfig) -> String {
        if let site = config.publicAvailableSites.first(where: { $0.key == siteKey }) {
            return site.name
        }
        return "来源已停用 · \(siteKey)"
    }

    public static func matchingHistory(
        siteKey: String,
        videoId: String,
        in history: [WatchHistoryItem]
    ) -> WatchHistoryItem? {
        history.first { $0.site == siteKey && $0.id == videoId }
    }

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
            return .ready(site: site, video: detailed, resumeHistory: resume)
        }
    }
}

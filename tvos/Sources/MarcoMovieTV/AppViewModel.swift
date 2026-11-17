// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MarcoTVCore
import SwiftUI

public enum LivingRoomTab: String, CaseIterable, Identifiable {
    case discover = "发现"
    case live = "直播"
    case search = "搜索"
    case library = "片库"
    case settings = "设置"

    public var id: String { rawValue }
}

public struct ActivePlaybackSession: Identifiable, Hashable {
    public let id = UUID()
    public var site: CmsSite
    public var video: CmsVideo
    public var lineIndex: Int
    public var episodeIndex: Int
    public var initialSeekMs: Int
    public var isLiveStream: Bool
    public var liveFlatChannels: [LiveChannel]
    public var liveChannelIndex: Int

    public init(
        site: CmsSite,
        video: CmsVideo,
        lineIndex: Int,
        episodeIndex: Int,
        initialSeekMs: Int = 0,
        isLiveStream: Bool = false,
        liveFlatChannels: [LiveChannel] = [],
        liveChannelIndex: Int = 0
    ) {
        self.site = site
        self.video = video
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
        self.initialSeekMs = initialSeekMs
        self.isLiveStream = isLiveStream
        self.liveFlatChannels = liveFlatChannels
        self.liveChannelIndex = liveChannelIndex
    }
}

@MainActor
public final class AppViewModel: ObservableObject {
    public let storage: TvStorageManager
    public let cmsClient: CmsClient
    public let proxyServer: LocalHeaderProxyServer
    public let webdavService: WebDavSyncService

    @Published public var selectedTab: LivingRoomTab = .discover
    @Published public private(set) var config = CmsConfig()
    @Published public private(set) var subscriptions: [SubscriptionEntry] = []
    @Published public private(set) var watchHistory: [WatchHistoryItem] = []
    @Published public private(set) var favorites: [FavoriteItem] = []
    @Published public private(set) var preferences = PlaybackPreferences()
    @Published public var webdavConfig = WebDavConfig()

    // Discover state
    @Published public private(set) var activeSite: CmsSite?
    @Published public private(set) var categories: [CmsCategory] = []
    @Published public var selectedCategoryId: String = ""
    @Published public private(set) var discoverVideos: [CmsVideo] = []
    @Published public private(set) var currentPage: Int = 1
    @Published public private(set) var totalPageCount: Int = 1
    @Published public private(set) var isLoadingDiscover = false
    @Published public private(set) var isLoadingMore = false
    @Published public var discoverError: String?
    @Published public var backdropPosterUrl: String = ""

    // Detail navigation & playback
    @Published public var selectedDetailContext: (site: CmsSite, video: CmsVideo)?
    @Published public var activePlayback: ActivePlaybackSession?

    // Live TV state
    @Published public var selectedLiveSourceIndex: Int = 0
    @Published public private(set) var liveGroups: [LiveGroup] = []
    @Published public var selectedLiveGroupIndex: Int = 0
    @Published public private(set) var isLoadingLive = false
    @Published public var liveError: String?

    // Global Search state
    @Published public var searchQuery: String = ""
    @Published public private(set) var searchBatches: [SiteSearchBatch] = []
    @Published public private(set) var isSearching = false

    // LAN QR & Modals
    @Published public var showSiteSwitcherSheet = false
    @Published public var showLanQrModal = false
    @Published public private(set) var lanQrUrl: String = ""
    @Published public var statusBannerMessage: String?
    @Published public private(set) var isSyncingWebDav = false

    private var lanServer: LanConfigServer?
    private var searchTask: Task<Void, Never>?

    public init(
        storage: TvStorageManager = TvStorageManager(),
        cmsClient: CmsClient = CmsClient(),
        proxyServer: LocalHeaderProxyServer = LocalHeaderProxyServer()
    ) {
        self.storage = storage
        self.cmsClient = cmsClient
        self.proxyServer = proxyServer
        self.webdavService = WebDavSyncService(storage: storage)

        reloadLocalState()
        Task {
            await performSelfHealingStartupIfNeeded()
        }
    }

    public var hasConfiguredSources: Bool {
        !config.sites.isEmpty || !config.lives.isEmpty || !config.depots.isEmpty
    }

    public func reloadLocalState() {
        subscriptions = storage.subscriptions()
        watchHistory = storage.watchHistory()
        favorites = storage.favorites()
        preferences = storage.preferences()
        webdavConfig = storage.loadWebDavConfig()
        config = storage.mergedConfig()

        let avail = config.publicAvailableSites
        if let match = avail.first(where: { $0.key == preferences.selectedSiteKey }) {
            activeSite = match
        } else if let fallback = avail.first(where: { !$0.isBannerNoticeSite }) ?? avail.first {
            activeSite = fallback
            storage.updatePreferences { $0.selectedSiteKey = fallback.key }
            preferences = storage.preferences()
        } else {
            activeSite = nil
        }

        if let firstPoster = watchHistory.first?.poster, !firstPoster.isEmpty {
            backdropPosterUrl = firstPoster
        }
    }

    private func performSelfHealingStartupIfNeeded() async {
        if storage.needsSubscriptionContentRefresh {
            for sub in storage.subscriptions() where !sub.url.isEmpty && sub.rawContent.isEmpty {
                if let (raw, _) = try? await cmsClient.fetchConfig(from: sub.url, defaultName: sub.name) {
                    _ = try? storage.upsertSubscription(
                        name: sub.name,
                        url: sub.url,
                        rawContent: raw,
                        warehouseUrl: sub.warehouseUrl,
                        activeDepotName: sub.activeDepotName
                    )
                }
            }
            reloadLocalState()
        }
        if webdavConfig.isConfigured && webdavConfig.autoSync {
            _ = try? await webdavService.syncNow()
            reloadLocalState()
        }
        if activeSite != nil && discoverVideos.isEmpty {
            await loadHomeForActiveSite()
        }
        if !config.supportedLives.isEmpty && liveGroups.isEmpty {
            await loadLiveCatalog(sourceIndex: 0)
        }
    }

    // MARK: - Site & Multi-Depot Switching

    public func selectSite(_ site: CmsSite) {
        guard site.supported else {
            statusBannerMessage = site.unsupportedReason
            return
        }
        activeSite = site
        storage.updatePreferences { $0.selectedSiteKey = site.key }
        preferences = storage.preferences()
        selectedCategoryId = ""
        Task {
            await loadHomeForActiveSite()
        }
    }

    public func switchDepot(_ depot: CmsDepot) async {
        isLoadingDiscover = true
        discoverError = nil
        do {
            let (rawText, _) = try await cmsClient.fetchDepotConfig(depot)
            let parentSub = subscriptions.first { $0.id == depot.subscriptionId } ?? subscriptions.first
            let warehouse = parentSub?.warehouseUrl.isEmpty == false ? (parentSub?.warehouseUrl ?? "") : (parentSub?.url ?? "")
            _ = try storage.upsertSubscription(
                name: depot.name,
                url: depot.url,
                rawContent: rawText,
                warehouseUrl: warehouse,
                activeDepotName: depot.name
            )
            if !depot.subscriptionId.isEmpty, let oldParent = parentSub {
                var all = storage.subscriptions()
                if let idx = all.firstIndex(where: { $0.activeDepotName == depot.name }) {
                    all[idx].depots = oldParent.depots
                    storage.saveSubscriptions(all)
                }
            }
            reloadLocalState()
            statusBannerMessage = "已切换至仓库：\(depot.name)"
            await loadHomeForActiveSite()
        } catch {
            discoverError = error.localizedDescription
        }
        isLoadingDiscover = false
    }

    public func importSubscriptionFromUrl(_ rawUrl: String, name: String = "") async throws {
        let normalized = CmsParser.extractAndNormalizeUrl(rawUrl)
        guard !normalized.isEmpty else {
            throw MarcoError.invalidFormat("请输入有效的 HTTP(S) 配置地址")
        }
        let (fetchedRaw, firstCfg) = try await cmsClient.fetchConfig(from: normalized, defaultName: name)
        if firstCfg.isMultiDepotOnly, let firstDepot = firstCfg.depots.first {
            let (depotRaw, _) = try await cmsClient.fetchDepotConfig(firstDepot)
            _ = try storage.upsertSubscription(
                name: name.isEmpty ? firstDepot.name : name,
                url: firstDepot.url,
                rawContent: depotRaw,
                warehouseUrl: normalized,
                activeDepotName: firstDepot.name
            )
            var subs = storage.subscriptions()
            if !subs.isEmpty {
                subs[0].depots = firstCfg.depots
                storage.saveSubscriptions(subs)
            }
        } else {
            _ = try storage.upsertSubscription(name: name, url: normalized, rawContent: fetchedRaw)
        }
        reloadLocalState()
        await loadHomeForActiveSite()
        if !config.supportedLives.isEmpty {
            await loadLiveCatalog(sourceIndex: 0)
        }
    }

    // MARK: - Discover & Pagination

    public func loadHomeForActiveSite() async {
        guard let site = activeSite else {
            categories = []
            discoverVideos = []
            return
        }
        isLoadingDiscover = true
        discoverError = nil
        do {
            let payload = try await cmsClient.fetchHome(site: site)
            categories = payload.categories
            discoverVideos = payload.listing.videos
            currentPage = payload.listing.page
            totalPageCount = payload.listing.pageCount
            if let firstPoster = discoverVideos.first(where: { !$0.poster.isEmpty })?.poster {
                backdropPosterUrl = firstPoster
            }
        } catch {
            discoverError = error.localizedDescription
        }
        isLoadingDiscover = false
    }

    public func selectCategory(_ categoryId: String) async {
        selectedCategoryId = categoryId
        guard let site = activeSite else { return }
        if categoryId.isEmpty {
            await loadHomeForActiveSite()
            return
        }
        isLoadingDiscover = true
        discoverError = nil
        do {
            let listing = try await cmsClient.fetchCategory(site: site, categoryId: categoryId, page: 1)
            discoverVideos = listing.videos
            currentPage = listing.page
            totalPageCount = listing.pageCount
        } catch {
            discoverError = error.localizedDescription
        }
        isLoadingDiscover = false
    }

    public func loadMoreDiscoverIfNeeded(currentVideo: CmsVideo) async {
        guard !isLoadingDiscover, !isLoadingMore, currentPage < totalPageCount, let site = activeSite else {
            return
        }
        guard let idx = discoverVideos.firstIndex(where: { $0.id == currentVideo.id }),
              idx >= max(0, discoverVideos.count - 6)
        else {
            return
        }
        isLoadingMore = true
        let nextPage = currentPage + 1
        if let nextListing = try? await cmsClient.fetchCategory(
            site: site,
            categoryId: selectedCategoryId,
            page: nextPage
        ) {
            let existingIds = Set(discoverVideos.map(\.id))
            let fresh = nextListing.videos.filter { !existingIds.contains($0.id) }
            discoverVideos.append(contentsOf: fresh)
            currentPage = nextPage
            totalPageCount = max(totalPageCount, nextListing.pageCount)
        }
        isLoadingMore = false
    }

    // MARK: - Live TV

    public func loadLiveCatalog(sourceIndex: Int) async {
        let lives = config.supportedLives
        guard lives.indices.contains(sourceIndex) else {
            liveGroups = []
            return
        }
        selectedLiveSourceIndex = sourceIndex
        selectedLiveGroupIndex = 0
        isLoadingLive = true
        liveError = nil
        do {
            liveGroups = try await cmsClient.fetchLiveGroups(for: lives[sourceIndex])
        } catch {
            liveError = error.localizedDescription
        }
        isLoadingLive = false
    }

    public func startLivePlayback(channel: LiveChannel) {
        let allChannels = liveGroups.flatMap(\.channels)
        let flatIdx = allChannels.firstIndex(of: channel) ?? 0
        let liveSite = CmsSite(
            key: "live_tv",
            name: "电视直播",
            type: 1,
            api: "http://127.0.0.1/live"
        )
        let video = CmsVideo(
            id: channel.id,
            title: channel.name,
            poster: channel.logo,
            remarks: channel.group,
            lines: [CmsLine(name: channel.group, episodes: channel.episodes)]
        )
        activePlayback = ActivePlaybackSession(
            site: liveSite,
            video: video,
            lineIndex: 0,
            episodeIndex: 0,
            initialSeekMs: 0,
            isLiveStream: true,
            liveFlatChannels: allChannels,
            liveChannelIndex: flatIdx
        )
    }

    // MARK: - Concurrent Multi-Site Search

    public func triggerGlobalSearch() {
        let kw = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        storage.addSearchKeyword(kw)
        searchTask?.cancel()
        searchBatches = []
        isSearching = true

        let sitesSnapshot = config.publicAvailableSites
        searchTask = Task { [weak self] in
            guard let client = self?.cmsClient else { return }
            _ = await client.searchAllSites(sites: sitesSnapshot, keyword: kw) { [weak self] batch in
                await MainActor.run { [weak self] in
                    guard let strongSelf = self, !Task.isCancelled else { return }
                    strongSelf.searchBatches.append(batch)
                }
            }
            if !Task.isCancelled {
                self?.isSearching = false
            }
        }
    }

    // MARK: - History, Favorites & Playback Persistence

    public func startVodPlayback(site: CmsSite, video: CmsVideo, lineIndex: Int, episodeIndex: Int, resumeMs: Int = 0) {
        let skipIntroMs = preferences.skipIntroSec * 1000
        let effectiveSeek = resumeMs > 0 ? resumeMs : skipIntroMs
        activePlayback = ActivePlaybackSession(
            site: site,
            video: video,
            lineIndex: lineIndex,
            episodeIndex: episodeIndex,
            initialSeekMs: effectiveSeek,
            isLiveStream: false
        )
    }

    public func recordPlaybackProgress(
        site: CmsSite,
        video: CmsVideo,
        lineName: String,
        episodeName: String,
        episodeIndex: Int,
        positionMs: Int,
        durationMs: Int
    ) {
        guard site.key != "live_tv" else { return }
        let entry = WatchHistoryItem(
            site: site.key,
            id: video.id,
            title: video.title,
            poster: video.poster,
            line: lineName,
            episode: episodeName,
            index: episodeIndex,
            position: positionMs,
            duration: durationMs,
            updated: Int64(Date().timeIntervalSince1970 * 1000)
        )
        storage.upsertWatchHistory(entry)
        watchHistory = storage.watchHistory()
    }

    public func toggleFavorite(site: CmsSite, video: CmsVideo) {
        _ = storage.toggleFavorite(site: site.key, video: video)
        favorites = storage.favorites()
    }

    public func removeHistoryItem(_ item: WatchHistoryItem) {
        storage.removeWatchHistory(site: item.site, id: item.id)
        watchHistory = storage.watchHistory()
    }

    public func clearAllHistory() {
        storage.clearWatchHistory()
        watchHistory = []
    }

    public func removeFavoriteItem(_ item: FavoriteItem) {
        storage.removeFavorite(site: item.site, id: item.id)
        favorites = storage.favorites()
    }

    public func clearAllFavorites() {
        storage.clearFavorites()
        favorites = []
    }

    public func updatePlaybackPreferences(_ mutate: (inout PlaybackPreferences) -> Void) {
        storage.updatePreferences(mutate)
        preferences = storage.preferences()
    }

    // MARK: - LAN QR Server & WebDAV Sync

    public func openLanQrModal() {
        showLanQrModal = true
        Task {
            await startOrRefreshLanServer()
        }
    }

    public func closeLanQrModal() {
        showLanQrModal = false
        lanServer?.stop()
        lanServer = nil
    }

    public func startOrRefreshLanServer() async {
        lanServer?.stop()
        let server = LanConfigServer(
            storage: storage,
            syncService: webdavService,
            cmsClient: cmsClient
        ) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.statusBannerMessage = event.message
                self.reloadLocalState()
                await self.loadHomeForActiveSite()
            }
        }
        if let _ = try? await server.start() {
            lanServer = server
            let host = LanConfigServer.discoverLanAddresses().first ?? "127.0.0.1"
            lanQrUrl = server.configureUrl(forHost: host)
        }
    }

    public func triggerManualWebDavSync() async {
        isSyncingWebDav = true
        defer { isSyncingWebDav = false }
        do {
            try storage.saveWebDavConfig(webdavConfig)
            let summary = try await webdavService.syncNow()
            reloadLocalState()
            statusBannerMessage = "云同步完成：历史 \(summary.historyCount) · 收藏 \(summary.favoriteCount) · 订阅 \(summary.subscriptionCount)"
            if discoverVideos.isEmpty {
                await loadHomeForActiveSite()
            }
        } catch {
            webdavConfig = storage.loadWebDavConfig()
            statusBannerMessage = error.localizedDescription
        }
    }
}

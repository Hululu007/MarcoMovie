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

public struct DetailRouteContext: Identifiable, Hashable {
    public var id: String { "\(site.key)\n\(video.id)" }
    public let site: CmsSite
    public let video: CmsVideo

    public init(site: CmsSite, video: CmsVideo) {
        self.site = site
        self.video = video
    }
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
    public let rangeProxyServer: NetdiskRangeProxyServer
    public let netdiskService: NetdiskService
    public let webdavService: WebDavSyncService

    @Published public var selectedTab: LivingRoomTab = .discover
    @Published public private(set) var config = CmsConfig()
    @Published public private(set) var subscriptions: [SubscriptionEntry] = []
    @Published public private(set) var watchHistory: [WatchHistoryItem] = []
    @Published public private(set) var favorites: [FavoriteItem] = []
    @Published public private(set) var preferences = PlaybackPreferences()
    @Published public var webdavConfig = WebDavConfig()
    @Published public private(set) var loggedInNetdiskDrives: Set<String> = []

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
    @Published public var selectedDetailContext: DetailRouteContext?
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

    // Privacy & per-source in-flight request guards
    private var sourceInvalidationCounter: UInt64 = 0
    private var siteInvalidationEpochs: [String: UInt64] = [:]
    private var liveInvalidationEpochs: [String: UInt64] = [:]
    private var discoverRequestToken: UInt64 = 0
    private var liveRequestToken: UInt64 = 0
    private var searchRequestToken: UInt64 = 0
    private var loadedLiveSourceIdentity: String?
    private var loadingLiveSourceIdentity: String?
    private var activeLiveSourceIdentity: String?
    private var liveLoadTask: Task<Void, Never>?

    // LAN QR, Netdisk & Modals
    @Published public var showSiteSwitcherSheet = false
    @Published public var showLanQrModal = false
    @Published public var showNetdiskSheet = false
    @Published public var selectedNetdiskDriveKey: String = "quark"
    @Published public private(set) var lanQrUrl: String = ""
    @Published public var statusBannerMessage: String?
    @Published public private(set) var isSyncingWebDav = false

    private var lanServer: LanConfigServer?
    private var searchTask: Task<Void, Never>?

    public init(
        storage: TvStorageManager = TvStorageManager(),
        cmsClient: CmsClient = CmsClient(),
        proxyServer: LocalHeaderProxyServer = LocalHeaderProxyServer(),
        rangeProxyServer: NetdiskRangeProxyServer = NetdiskRangeProxyServer(),
        netdiskService: NetdiskService = NetdiskService()
    ) {
        self.storage = storage
        self.cmsClient = cmsClient
        self.proxyServer = proxyServer
        self.rangeProxyServer = rangeProxyServer
        self.netdiskService = netdiskService
        self.webdavService = WebDavSyncService(storage: storage)

        reloadLocalState()
        Task {
            await performSelfHealingStartupIfNeeded()
        }
    }

    public var hasConfiguredSources: Bool {
        !config.publicAvailableSites.isEmpty || !config.publicSupportedLives.isEmpty || !config.publicDepots.isEmpty
    }

    public func reloadLocalState() {
        let previousActiveKey = activeSite?.key
        let previousPublicSiteKeys = Set(config.publicAvailableSites.map(\.key))
        let previousPublicLiveIds = Set(config.publicSupportedLives.map(PublicCatalogScopeGuard.liveSourceIdentity))

        subscriptions = storage.subscriptions()
        preferences = storage.preferences()
        webdavConfig = storage.loadWebDavConfig()
        loggedInNetdiskDrives = Set(storage.loggedInNetdiskDrives())
        config = storage.mergedConfig()
        watchHistory = MediaEntryResolver.publicVisibleWatchHistory(storage.watchHistory(), in: config)
        favorites = MediaEntryResolver.publicVisibleFavorites(storage.favorites(), in: config)

        let avail = config.publicAvailableSites
        let publicSiteKeys = Set(avail.map(\.key))
        let publicLiveIds = Set(config.publicSupportedLives.map(PublicCatalogScopeGuard.liveSourceIdentity))
        // Invalidate ONLY sources that actually disappeared or turned private, so deleting an
        // unrelated subscription B never aborts or stalls an active slow load for still-public source A.
        for removedSiteKey in previousPublicSiteKeys.subtracting(publicSiteKeys) {
            sourceInvalidationCounter &+= 1
            siteInvalidationEpochs[removedSiteKey] = sourceInvalidationCounter
        }
        for removedLiveId in previousPublicLiveIds.subtracting(publicLiveIds) {
            sourceInvalidationCounter &+= 1
            liveInvalidationEpochs[removedLiveId] = sourceInvalidationCounter
        }

        let resolvedSelected: CmsSite? = {
            if let direct = avail.first(where: { $0.key == preferences.selectedSiteKey }) {
                return direct
            }
            if case .available(let legacyMatched) = MediaEntryResolver.lookupOriginSite(
                siteKey: preferences.selectedSiteKey,
                in: config
            ) {
                return legacyMatched
            }
            return nil
        }()

        if let match = resolvedSelected {
            activeSite = match
            if preferences.selectedSiteKey != match.key {
                storage.updatePreferences { $0.selectedSiteKey = match.key }
                preferences = storage.preferences()
            }
        } else if let fallback = avail.first(where: { !$0.isBannerNoticeSite }) ?? avail.first {
            activeSite = fallback
            storage.updatePreferences { $0.selectedSiteKey = fallback.key }
            preferences = storage.preferences()
        } else {
            activeSite = nil
        }

        if activeSite?.key != previousActiveKey {
            discoverRequestToken &+= 1
            categories = []
            discoverVideos = []
            selectedCategoryId = ""
            discoverError = nil
            isLoadingDiscover = false
            isLoadingMore = false
        }

        // Purge any in-memory search results whose sources became private or disabled;
        // late batches from removed/private sites are rejected per-site via siteInvalidationEpochs.
        searchBatches = searchBatches.filter { publicSiteKeys.contains($0.site.key) }
        if publicSiteKeys.isEmpty {
            searchTask?.cancel()
            searchRequestToken &+= 1
            isSearching = false
        }

        // Reconcile Live TV strictly by source identity (not list index!) so switching a live
        // source to private clears its channels even when another public live source shifts into
        // the exact same `selectedLiveSourceIndex`, while deleting an unrelated live source does
        // not abort an in-flight load for a still-public live source.
        if let loadedId = loadedLiveSourceIdentity, !publicLiveIds.contains(loadedId) {
            loadedLiveSourceIdentity = nil
            selectedLiveGroupIndex = 0
            liveGroups = []
        }
        let liveReconciliation = PublicCatalogScopeGuard.reconcileLiveSourceSelection(
            previousLoadedIdentity: loadingLiveSourceIdentity ?? loadedLiveSourceIdentity,
            currentSelectedIndex: selectedLiveSourceIndex,
            publicLives: config.publicSupportedLives
        )
        selectedLiveSourceIndex = liveReconciliation.nextIndex
        if liveReconciliation.shouldClearLoadedGroups {
            liveLoadTask?.cancel()
            liveLoadTask = nil
            liveRequestToken &+= 1
            loadedLiveSourceIdentity = nil
            loadingLiveSourceIdentity = nil
            selectedLiveGroupIndex = 0
            liveGroups = []
            liveError = nil
            isLoadingLive = false
        } else if loadingLiveSourceIdentity == nil {
            loadedLiveSourceIdentity = liveReconciliation.nextLoadedIdentity
        }

        if let openCtx = selectedDetailContext, !publicSiteKeys.contains(openCtx.site.key) {
            selectedDetailContext = nil
        }

        if let playing = activePlayback {
            if playing.isLiveStream {
                if let activeLiveId = activeLiveSourceIdentity, !publicLiveIds.contains(activeLiveId) {
                    activePlayback = nil
                    activeLiveSourceIdentity = nil
                }
            } else if !publicSiteKeys.contains(playing.site.key) || config.isPrivateSiteKey(playing.site.key) {
                activePlayback = nil
            }
        }

        backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: preferences.ambientPosterSync,
            publicDiscoverVideos: discoverVideos,
            publicWatchHistory: watchHistory,
            config: config
        )
    }

    private func performSelfHealingStartupIfNeeded() async {
        if storage.needsSubscriptionContentRefresh {
            for sub in storage.subscriptions()
                where sub.enabled && !sub.isEffectivelyPrivate && !sub.url.isEmpty && sub.rawContent.isEmpty
            {
                if let (raw, _) = try? await cmsClient.fetchConfig(from: sub.url, defaultName: sub.name) {
                    _ = try? storage.upsertSubscription(
                        id: sub.id,
                        name: sub.name,
                        url: sub.url,
                        rawContent: raw,
                        group: sub.group,
                        isPrivate: sub.isEffectivelyPrivate,
                        enabled: sub.enabled,
                        warehouseUrl: sub.warehouseUrl,
                        activeDepotName: sub.activeDepotName,
                        depots: sub.depots
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
        if !config.publicSupportedLives.isEmpty && liveGroups.isEmpty {
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
            let parentSub = !depot.subscriptionId.isEmpty
                ? subscriptions.first { $0.id == depot.subscriptionId }
                : subscriptions.first { $0.depots.contains(where: { $0.url == depot.url }) } ?? subscriptions.first
            let warehouse = parentSub?.warehouseUrl.isEmpty == false ? (parentSub?.warehouseUrl ?? "") : (parentSub?.url ?? "")
            _ = try storage.upsertSubscription(
                id: parentSub?.id,
                name: depot.name,
                url: depot.url,
                rawContent: rawText,
                group: parentSub?.group,
                isPrivate: parentSub?.isEffectivelyPrivate,
                enabled: parentSub?.enabled,
                warehouseUrl: warehouse,
                activeDepotName: depot.name,
                depots: parentSub?.depots
            )
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
                activeDepotName: firstDepot.name,
                depots: firstCfg.depots
            )
        } else {
            _ = try storage.upsertSubscription(name: name, url: normalized, rawContent: fetchedRaw)
        }
        reloadLocalState()
        await loadHomeForActiveSite()
        if !config.publicSupportedLives.isEmpty {
            await loadLiveCatalog(sourceIndex: 0)
        }
    }

    // MARK: - Discover & Pagination

    public func loadHomeForActiveSite() async {
        guard let site = activeSite else {
            categories = []
            discoverVideos = []
            isLoadingDiscover = false
            return
        }
        discoverRequestToken &+= 1
        let reqToken = discoverRequestToken
        let reqSiteKey = site.key
        let reqEpoch = siteInvalidationEpochs[reqSiteKey, default: 0]
        isLoadingDiscover = true
        discoverError = nil
        defer {
            if reqToken == discoverRequestToken {
                isLoadingDiscover = false
            }
        }
        do {
            let payload = try await cmsClient.fetchHome(site: site)
            guard !Task.isCancelled,
                  reqToken == discoverRequestToken,
                  PublicCatalogScopeGuard.canAcceptDiscoverResponse(
                      siteKey: reqSiteKey,
                      requestEpoch: reqEpoch,
                      currentEpoch: siteInvalidationEpochs[reqSiteKey, default: 0],
                      activeSiteKey: activeSite?.key,
                      config: config
                  )
            else {
                return
            }
            categories = payload.categories
            discoverVideos = payload.listing.videos
            currentPage = payload.listing.page
            totalPageCount = payload.listing.pageCount
            backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
                ambientPosterSync: preferences.ambientPosterSync,
                publicDiscoverVideos: discoverVideos,
                publicWatchHistory: watchHistory,
                config: config
            )
        } catch {
            guard reqToken == discoverRequestToken,
                  reqEpoch == siteInvalidationEpochs[reqSiteKey, default: 0],
                  activeSite?.key == reqSiteKey,
                  !config.isPrivateSiteKey(reqSiteKey)
            else {
                return
            }
            discoverError = error.localizedDescription
        }
    }

    public func selectCategory(_ categoryId: String) async {
        selectedCategoryId = categoryId
        guard let site = activeSite else { return }
        if categoryId.isEmpty {
            await loadHomeForActiveSite()
            return
        }
        discoverRequestToken &+= 1
        let reqToken = discoverRequestToken
        let reqSiteKey = site.key
        let reqEpoch = siteInvalidationEpochs[reqSiteKey, default: 0]
        isLoadingDiscover = true
        discoverError = nil
        defer {
            if reqToken == discoverRequestToken {
                isLoadingDiscover = false
            }
        }
        do {
            let listing = try await cmsClient.fetchCategory(site: site, categoryId: categoryId, page: 1)
            guard !Task.isCancelled,
                  reqToken == discoverRequestToken,
                  selectedCategoryId == categoryId,
                  PublicCatalogScopeGuard.canAcceptDiscoverResponse(
                      siteKey: reqSiteKey,
                      requestEpoch: reqEpoch,
                      currentEpoch: siteInvalidationEpochs[reqSiteKey, default: 0],
                      activeSiteKey: activeSite?.key,
                      config: config
                  )
            else {
                return
            }
            discoverVideos = listing.videos
            currentPage = listing.page
            totalPageCount = listing.pageCount
        } catch {
            guard reqToken == discoverRequestToken,
                  reqEpoch == siteInvalidationEpochs[reqSiteKey, default: 0],
                  activeSite?.key == reqSiteKey,
                  !config.isPrivateSiteKey(reqSiteKey)
            else {
                return
            }
            discoverError = error.localizedDescription
        }
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
        let reqToken = discoverRequestToken
        let reqSiteKey = site.key
        let reqEpoch = siteInvalidationEpochs[reqSiteKey, default: 0]
        let reqCategoryId = selectedCategoryId
        isLoadingMore = true
        defer {
            if reqToken == discoverRequestToken {
                isLoadingMore = false
            }
        }
        let nextPage = currentPage + 1
        if let nextListing = try? await cmsClient.fetchCategory(
            site: site,
            categoryId: reqCategoryId,
            page: nextPage
        ) {
            guard !Task.isCancelled,
                  reqToken == discoverRequestToken,
                  selectedCategoryId == reqCategoryId,
                  PublicCatalogScopeGuard.canAcceptDiscoverResponse(
                      siteKey: reqSiteKey,
                      requestEpoch: reqEpoch,
                      currentEpoch: siteInvalidationEpochs[reqSiteKey, default: 0],
                      activeSiteKey: activeSite?.key,
                      config: config
                  )
            else {
                return
            }
            let existingIds = Set(discoverVideos.map(\.id))
            let fresh = nextListing.videos.filter { !existingIds.contains($0.id) }
            discoverVideos.append(contentsOf: fresh)
            currentPage = nextPage
            totalPageCount = max(totalPageCount, nextListing.pageCount)
        }
    }

    // MARK: - Live TV

    public func loadLiveCatalog(sourceIndex: Int) async {
        liveLoadTask?.cancel()
        liveLoadTask = nil
        let lives = config.publicSupportedLives
        guard lives.indices.contains(sourceIndex) else {
            liveGroups = []
            loadedLiveSourceIdentity = nil
            loadingLiveSourceIdentity = nil
            isLoadingLive = false
            return
        }
        let targetSource = lives[sourceIndex]
        let targetIdentity = PublicCatalogScopeGuard.liveSourceIdentity(targetSource)
        liveRequestToken &+= 1
        let reqToken = liveRequestToken
        let reqEpoch = liveInvalidationEpochs[targetIdentity, default: 0]

        selectedLiveSourceIndex = sourceIndex
        selectedLiveGroupIndex = 0
        loadingLiveSourceIdentity = targetIdentity
        isLoadingLive = true
        liveError = nil
        let client = cmsClient
        let task = Task { [weak self] in
            do {
                let groups = try await client.fetchLiveGroups(for: targetSource)
                await MainActor.run { [weak self] in
                    guard let strongSelf = self else { return }
                    defer {
                        if reqToken == strongSelf.liveRequestToken {
                            strongSelf.isLoadingLive = false
                            if strongSelf.loadingLiveSourceIdentity == targetIdentity {
                                strongSelf.loadingLiveSourceIdentity = nil
                            }
                        }
                    }
                    guard !Task.isCancelled,
                          PublicCatalogScopeGuard.canAcceptLiveResponse(
                              sourceIdentity: targetIdentity,
                              requestToken: reqToken,
                              currentToken: strongSelf.liveRequestToken,
                              requestEpoch: reqEpoch,
                              currentEpoch: strongSelf.liveInvalidationEpochs[targetIdentity, default: 0],
                              config: strongSelf.config
                          )
                    else {
                        return
                    }
                    strongSelf.liveGroups = groups
                    strongSelf.loadedLiveSourceIdentity = targetIdentity
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let strongSelf = self else { return }
                    defer {
                        if reqToken == strongSelf.liveRequestToken {
                            strongSelf.isLoadingLive = false
                            if strongSelf.loadingLiveSourceIdentity == targetIdentity {
                                strongSelf.loadingLiveSourceIdentity = nil
                            }
                        }
                    }
                    guard !Task.isCancelled,
                          reqToken == strongSelf.liveRequestToken,
                          reqEpoch == strongSelf.liveInvalidationEpochs[targetIdentity, default: 0],
                          strongSelf.config.publicSupportedLives.contains(where: {
                              PublicCatalogScopeGuard.liveSourceIdentity($0) == targetIdentity
                          })
                    else {
                        return
                    }
                    strongSelf.liveError = error.localizedDescription
                }
            }
        }
        liveLoadTask = task
        await task.value
    }

    public func startLivePlayback(channel: LiveChannel) {
        let allChannels = liveGroups.flatMap(\.channels)
        let flatIdx = allChannels.firstIndex(of: channel) ?? 0
        let activeLiveSource = config.publicSupportedLives.indices.contains(selectedLiveSourceIndex)
            ? config.publicSupportedLives[selectedLiveSourceIndex]
            : nil
        activeLiveSourceIdentity = activeLiveSource.map(PublicCatalogScopeGuard.liveSourceIdentity)
        let liveSite = CmsSite(
            key: "live_tv",
            name: activeLiveSource?.name ?? "电视直播",
            type: 1,
            api: "http://127.0.0.1/live",
            headers: activeLiveSource?.headers ?? [:]
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

    // MARK: - Source-Bound Detail Opening (Continue Watching / History / Favorites)

    public func openDetail(site: CmsSite, video: CmsVideo) {
        if preferences.ambientPosterSync && !site.isEffectivelyPrivate && !video.poster.isEmpty {
            backdropPosterUrl = video.poster
        }
        selectedDetailContext = DetailRouteContext(site: site, video: video)
    }

    public func openWatchHistoryItem(_ item: WatchHistoryItem) {
        switch MediaEntryResolver.lookupOriginSite(siteKey: item.site, in: config) {
        case .available(let originSite):
            let stub = CmsVideo(
                id: item.id,
                title: item.title,
                poster: item.poster,
                remarks: item.episode
            )
            openDetail(site: originSite, video: stub)
        case .unavailable(_, let reason):
            statusBannerMessage = reason
        }
    }

    public func openFavoriteItem(_ fav: FavoriteItem) {
        switch MediaEntryResolver.lookupOriginSite(siteKey: fav.site, in: config) {
        case .available(let originSite):
            let stub = CmsVideo(
                id: fav.id,
                title: fav.title,
                poster: fav.poster,
                remarks: fav.remarks
            )
            openDetail(site: originSite, video: stub)
        case .unavailable(_, let reason):
            statusBannerMessage = reason
        }
    }

    public func originSourceDisplayName(for siteKey: String) -> String {
        MediaEntryResolver.sourceDisplayName(siteKey: siteKey, in: config)
    }

    // MARK: - Concurrent Multi-Site Search

    public func triggerGlobalSearch() {
        let kw = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        storage.addSearchKeyword(kw)
        searchTask?.cancel()
        searchRequestToken &+= 1
        let reqToken = searchRequestToken
        let sitesSnapshot = config.publicAvailableSites
        let reqEpochsBySite = Dictionary(
            uniqueKeysWithValues: sitesSnapshot.map { ($0.key, siteInvalidationEpochs[$0.key, default: 0]) }
        )
        searchBatches = []
        isSearching = true

        searchTask = Task { [weak self] in
            guard let client = self?.cmsClient else { return }
            _ = await client.searchAllSites(sites: sitesSnapshot, keyword: kw) { [weak self] batch in
                await MainActor.run { [weak self] in
                    guard let strongSelf = self,
                          !Task.isCancelled,
                          PublicCatalogScopeGuard.canAcceptSearchBatch(
                              siteKey: batch.site.key,
                              requestToken: reqToken,
                              currentToken: strongSelf.searchRequestToken,
                              requestEpoch: reqEpochsBySite[batch.site.key, default: 0],
                              currentEpoch: strongSelf.siteInvalidationEpochs[batch.site.key, default: 0],
                              config: strongSelf.config
                          )
                    else {
                        return
                    }
                    strongSelf.searchBatches.append(batch)
                }
            }
            await MainActor.run { [weak self] in
                guard let strongSelf = self,
                      !Task.isCancelled,
                      reqToken == strongSelf.searchRequestToken
                else {
                    return
                }
                strongSelf.isSearching = false
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
        watchHistory = MediaEntryResolver.publicVisibleWatchHistory(storage.watchHistory(), in: config)
        backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: preferences.ambientPosterSync,
            publicDiscoverVideos: discoverVideos,
            publicWatchHistory: watchHistory,
            config: config
        )
    }

    public func toggleFavorite(site: CmsSite, video: CmsVideo) {
        if let legacyMatch = MediaEntryResolver.matchingFavorite(
            for: site,
            videoId: video.id,
            in: storage.favorites(),
            config: config
        ), legacyMatch.site != site.key {
            storage.removeFavorite(site: legacyMatch.site, id: legacyMatch.id)
        } else {
            _ = storage.toggleFavorite(site: site.key, video: video)
        }
        favorites = MediaEntryResolver.publicVisibleFavorites(storage.favorites(), in: config)
    }

    public func removeHistoryItem(_ item: WatchHistoryItem) {
        storage.removeWatchHistory(site: item.site, id: item.id)
        watchHistory = MediaEntryResolver.publicVisibleWatchHistory(storage.watchHistory(), in: config)
        backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: preferences.ambientPosterSync,
            publicDiscoverVideos: discoverVideos,
            publicWatchHistory: watchHistory,
            config: config
        )
    }

    public func clearAllHistory() {
        let publicItems = MediaEntryResolver.publicVisibleWatchHistory(storage.watchHistory(), in: config)
        if publicItems.count == storage.watchHistory().count {
            storage.clearWatchHistory()
        } else {
            for item in publicItems {
                storage.removeWatchHistory(site: item.site, id: item.id)
            }
        }
        watchHistory = MediaEntryResolver.publicVisibleWatchHistory(storage.watchHistory(), in: config)
        backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: preferences.ambientPosterSync,
            publicDiscoverVideos: discoverVideos,
            publicWatchHistory: watchHistory,
            config: config
        )
    }

    public func removeFavoriteItem(_ item: FavoriteItem) {
        storage.removeFavorite(site: item.site, id: item.id)
        favorites = MediaEntryResolver.publicVisibleFavorites(storage.favorites(), in: config)
    }

    public func clearAllFavorites() {
        let publicItems = MediaEntryResolver.publicVisibleFavorites(storage.favorites(), in: config)
        if publicItems.count == storage.favorites().count {
            storage.clearFavorites()
        } else {
            for item in publicItems {
                storage.removeFavorite(site: item.site, id: item.id)
            }
        }
        favorites = MediaEntryResolver.publicVisibleFavorites(storage.favorites(), in: config)
    }

    public func updatePlaybackPreferences(_ mutate: (inout PlaybackPreferences) -> Void) {
        storage.updatePreferences(mutate)
        preferences = storage.preferences()
        backdropPosterUrl = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: preferences.ambientPosterSync,
            publicDiscoverVideos: discoverVideos,
            publicWatchHistory: watchHistory,
            config: config
        )
    }

    // MARK: - 4K Netdisk Accounts & LAN QR Server & WebDAV Sync

    public func openNetdiskSheet(preferredDriveKey: String? = nil) {
        if let key = preferredDriveKey, NetdiskDriveInfo.info(for: key) != nil {
            selectedNetdiskDriveKey = key
        }
        showNetdiskSheet = true
    }

    public func saveNetdiskCredential(driveKey: String, credential: String) throws {
        try storage.setNetdiskCredential(credential, for: driveKey)
        loggedInNetdiskDrives = Set(storage.loggedInNetdiskDrives())
        if let info = NetdiskDriveInfo.info(for: driveKey) {
            statusBannerMessage = "\(info.tvName)（\(info.providerName)）授权成功"
        }
    }

    public func logoutNetdisk(driveKey: String) {
        try? storage.removeNetdiskCredential(for: driveKey)
        loggedInNetdiskDrives = Set(storage.loggedInNetdiskDrives())
        let proxy = rangeProxyServer
        Task {
            await proxy.revokeAll()
        }
        if let info = NetdiskDriveInfo.info(for: driveKey) {
            statusBannerMessage = "已退出 \(info.tvName)"
        }
    }

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
            Task { @MainActor [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.statusBannerMessage = event.message
                strongSelf.reloadLocalState()
                await strongSelf.loadHomeForActiveSite()
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
            if summary.hasPendingLocalChanges {
                statusBannerMessage = "本轮云同步完成，但仍有改动待同步，请稍后再次同步"
            } else {
                statusBannerMessage = "云同步完成：历史 \(summary.historyCount) · 收藏 \(summary.favoriteCount) · 订阅 \(summary.subscriptionCount)"
            }
            if discoverVideos.isEmpty {
                await loadHomeForActiveSite()
            }
        } catch {
            webdavConfig = storage.loadWebDavConfig()
            statusBannerMessage = error.localizedDescription
        }
    }
}

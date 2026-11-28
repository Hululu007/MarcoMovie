// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct SiteHomePayload: Sendable {
    public var categories: [CmsCategory]
    public var listing: CmsListing

    public init(categories: [CmsCategory], listing: CmsListing) {
        self.categories = categories
        self.listing = listing
    }
}

public struct SiteSearchBatch: Identifiable, Hashable, Sendable {
    public var id: String { site.key }
    public var site: CmsSite
    public var videos: [CmsVideo]

    public init(site: CmsSite, videos: [CmsVideo]) {
        self.site = site
        self.videos = videos
    }
}

/// Async HTTP CMS client supporting JSON (`type == 1`), XML (`type == 0`), inline `m3u_vod://`,
/// Type-3 QuickJS spiders (`JsSourceHost`), multi-depot warehouses, concurrent multi-site search,
/// and header-proxied playback resolution.
public final class CmsClient: @unchecked Sendable {
    public static let defaultSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    public static let fallbackOkHttpUserAgent = "okhttp/4.12.0"

    private enum ScriptHostBackend {
        case spider(JsSourceHost)
        case drpy(DrpySourceHost)

        func homeContent(filter: Bool = true) async throws -> SiteHomePayload {
            switch self {
            case .spider(let h): return try await h.homeContent(filter: filter)
            case .drpy(let h): return try await h.homeContent(filter: filter)
            }
        }

        func categoryContent(tid: String, page: Int = 1) async throws -> CmsListing {
            switch self {
            case .spider(let h): return try await h.categoryContent(tid: tid, page: page)
            case .drpy(let h): return try await h.categoryContent(tid: tid, page: page)
            }
        }

        func detailContent(ids: [String]) async throws -> CmsVideo? {
            switch self {
            case .spider(let h): return try await h.detailContent(ids: ids)
            case .drpy(let h): return try await h.detailContent(ids: ids)
            }
        }

        func searchContent(keyword: String, quick: Bool = false, page: Int = 1) async throws -> [CmsVideo] {
            switch self {
            case .spider(let h): return try await h.searchContent(keyword: keyword, quick: quick, page: page)
            case .drpy(let h): return try await h.searchContent(keyword: keyword, quick: quick, page: page)
            }
        }

        func playerContent(flag: String, id: String, vipFlags: [String] = []) async throws -> JsResolvedPlayStream {
            switch self {
            case .spider(let h): return try await h.playerContent(flag: flag, id: id, vipFlags: vipFlags)
            case .drpy(let h): return try await h.playerContent(flag: flag, id: id, vipFlags: vipFlags)
            }
        }
    }

    private let session: URLSession
    private let netdiskResolver: NetdiskShareResolver
    private let jsHostCacheLock = NSLock()
    private var scriptHosts: [String: ScriptHostBackend] = [:]
    private var jarCache: [String: Data] = [:]

    public init(
        timeoutSeconds: TimeInterval = 15,
        netdiskResolver: NetdiskShareResolver? = nil,
        session: URLSession? = nil
    ) {
        let builtSession: URLSession = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeoutSeconds
            config.timeoutIntervalForResource = timeoutSeconds * 2
            config.httpShouldSetCookies = false
            return URLSession(configuration: config)
        }()
        self.session = builtSession
        self.netdiskResolver = netdiskResolver ?? NetdiskShareResolver(session: builtSession)
    }

    public func fetchRawBytes(
        url rawUrl: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> Data {
        let normalized = CmsParser.normalizeUrl(rawUrl)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MarcoError.invalidFormat("无效的 HTTP(S) 地址：\(rawUrl)")
        }

        let hasExplicitUA = headers.keys.contains { $0.lowercased() == "user-agent" }
        do {
            return try await performGet(
                url: url,
                headers: headers,
                defaultUA: Self.defaultSafariUserAgent,
                timeout: timeout
            )
        } catch {
            if !hasExplicitUA {
                return try await performGet(
                    url: url,
                    headers: headers,
                    defaultUA: Self.fallbackOkHttpUserAgent,
                    timeout: timeout
                )
            }
            throw error
        }
    }

    private func performGet(
        url: URL,
        headers: [String: String],
        defaultUA: String,
        timeout: TimeInterval
    ) async throws -> Data {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        var hasUA = false
        for (k, v) in headers {
            if k.lowercased() == "user-agent" { hasUA = true }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !hasUA {
            req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Subscription & Multi-Depot Loading

    public func fetchConfig(from urlString: String, defaultName: String = "") async throws -> (rawText: String, config: CmsConfig) {
        let cleanUrl = CmsParser.extractAndNormalizeUrl(urlString)
        let bytes = try await fetchRawBytes(url: cleanUrl, timeout: 18)
        let unpacked = try ConfigDecoder.decodeConfigDocument(bytes)
        if ConfigDecoder.isCatPawBundle(unpacked) {
            throw MarcoError.unsupportedSite("Apple TV (tvOS) 暂不支持运行 Node.js CatPaw 本机服务包，请导入标准 TVBox / DRPY 订阅，或在桌面端/iOS 端使用该订阅")
        }
        let parsed = try CmsParser.parseConfig(unpacked, origin: cleanUrl, defaultName: defaultName)
        return (unpacked, parsed)
    }

    public func fetchDepotConfig(_ depot: CmsDepot) async throws -> (rawText: String, config: CmsConfig) {
        try await fetchConfig(from: depot.url, defaultName: depot.name)
    }

    public func fetchLiveGroups(for source: LiveSource) async throws -> [LiveGroup] {
        if !source.inlineContent.isEmpty {
            return try CmsParser.parseLivePlaylist(source.inlineContent, origin: source.origin, headers: source.headers)
        }
        if source.url.lowercased().hasPrefix("data:"),
           let b64Range = source.url.range(of: "base64,")
        {
            let b64 = String(source.url[b64Range.upperBound...])
            if let data = Data(base64Encoded: b64) {
                let text = try ConfigDecoder.decodeTextDocument(data)
                return try CmsParser.parseLivePlaylist(text, origin: source.origin, headers: source.headers)
            }
        }
        let bytes = try await fetchRawBytes(url: source.url, headers: source.headers, timeout: 15)
        let text = try ConfigDecoder.decodeTextDocument(bytes)
        return try CmsParser.parseLivePlaylist(text, origin: source.url, headers: source.headers)
    }

    // MARK: - Home, Category, Detail & Concurrent Multi-Site Search

    public func fetchHome(site: CmsSite) async throws -> SiteHomePayload {
        guard site.supported else {
            throw MarcoError.unsupportedSite(site.unsupportedReason)
        }
        if site.isM3uVodApi {
            let (cats, listing) = try CmsParser.parseM3uVodHome(site.ext, origin: site.api)
            return SiteHomePayload(categories: cats, listing: listing)
        }
        if site.hasQuickJsAdapter {
            let host = try await resolveJsHost(for: site)
            return try await host.homeContent(filter: true)
        }

        // Standard CMS: try ac=videolist first for rich posters, and fetch categories via ac=list if needed
        let homeUrl = appendQuery(site.api, params: [("ac", "videolist"), ("pg", "1")])
        let homeData = try await fetchRawBytes(url: homeUrl, headers: site.headers)
        let homeText = try ConfigDecoder.decodeTextDocument(homeData)
        var categories = CmsParser.parseCategories(homeText)
        let listing = try CmsParser.parseListing(homeText)

        if categories.isEmpty {
            let listUrl = appendQuery(site.api, params: [("ac", "list")])
            if let listData = try? await fetchRawBytes(url: listUrl, headers: site.headers),
               let listText = try? ConfigDecoder.decodeTextDocument(listData)
            {
                categories = CmsParser.parseCategories(listText)
            }
        }
        return SiteHomePayload(categories: categories, listing: listing)
    }

    public func fetchCategory(site: CmsSite, categoryId: String, page: Int = 1) async throws -> CmsListing {
        guard site.supported else {
            throw MarcoError.unsupportedSite(site.unsupportedReason)
        }
        if site.isM3uVodApi {
            let (_, all) = try CmsParser.parseM3uVodHome(site.ext, origin: site.api)
            if categoryId.isEmpty { return all }
            let filtered = all.videos.filter { $0.tag == categoryId || $0.remarks == categoryId }
            return CmsListing(page: 1, pageCount: 1, videos: filtered)
        }
        if site.hasQuickJsAdapter {
            let host = try await resolveJsHost(for: site)
            return try await host.categoryContent(tid: categoryId, page: page)
        }

        var params: [(String, String)] = [("ac", "videolist"), ("pg", "\(max(1, page))")]
        if !categoryId.isEmpty {
            params.append(("t", categoryId))
        }
        let url = appendQuery(site.api, params: params)
        let bytes = try await fetchRawBytes(url: url, headers: site.headers)
        let text = try ConfigDecoder.decodeTextDocument(bytes)
        return try CmsParser.parseListing(text)
    }

    public func fetchDetail(site: CmsSite, video: CmsVideo) async throws -> CmsVideo {
        guard site.supported else {
            throw MarcoError.unsupportedSite(site.unsupportedReason)
        }
        if site.isM3uVodApi {
            if !video.lines.isEmpty {
                return video
            }
            let (_, listing) = try CmsParser.parseM3uVodHome(site.ext, origin: site.api)
            if let matched = listing.videos.first(where: { $0.id == video.id }) {
                return mergeVideoDetail(summary: video, detail: matched)
            }
            throw MarcoError.unsupportedSite("在原片源「\(site.name)」中未找到该 M3U 点播影片，请检查或刷新订阅")
        }
        if site.hasQuickJsAdapter {
            let host = try await resolveJsHost(for: site)
            let targetId = video.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detailed = try await host.detailContent(ids: [targetId]) {
                let returnedId = detailed.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !returnedId.isEmpty && returnedId != targetId {
                    throw MarcoError.unsupportedSite(
                        "原片源「\(site.name)」返回了不匹配的影片（期望 ID: \(targetId)，实际 ID: \(returnedId)），原片不可用，观看断点已保留"
                    )
                }
                return mergeVideoDetail(summary: video, detail: detailed)
            }
            if !video.lines.isEmpty {
                return video
            }
            throw MarcoError.unsupportedSite("原片源「\(site.name)」未返回目标影片（ID: \(targetId)），原片不可用，观看断点已保留")
        }
        if !video.lines.isEmpty && !video.description.isEmpty {
            return video
        }
        let targetId = video.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = appendQuery(site.api, params: [("ac", "detail"), ("ids", targetId)])
        let bytes = try await fetchRawBytes(url: url, headers: site.headers)
        let text = try ConfigDecoder.decodeTextDocument(bytes)
        let listing = try CmsParser.parseListing(text)
        guard let detail = listing.videos.first(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == targetId
        }) else {
            throw MarcoError.unsupportedSite("原片源「\(site.name)」未返回目标影片（ID: \(targetId)），原片不可用，观看断点已保留")
        }
        return mergeVideoDetail(summary: video, detail: detail)
    }

    public func searchSite(site: CmsSite, keyword: String, page: Int = 1) async throws -> [CmsVideo] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, site.supported, site.searchable, !site.isBannerNoticeSite else {
            return []
        }
        if site.isM3uVodApi {
            let (_, all) = try CmsParser.parseM3uVodHome(site.ext, origin: site.api)
            let lowerKw = trimmed.lowercased()
            return all.videos.filter { $0.title.lowercased().contains(lowerKw) }
        }
        if site.hasQuickJsAdapter {
            let host = try await resolveJsHost(for: site)
            return try await host.searchContent(keyword: trimmed, quick: false, page: page)
        }

        let detailSearchUrl = appendQuery(site.api, params: [("ac", "videolist"), ("wd", trimmed), ("pg", "\(max(1, page))")])
        let bytes = try await fetchRawBytes(url: detailSearchUrl, headers: site.headers, timeout: 10)
        let text = try ConfigDecoder.decodeTextDocument(bytes)
        let listing = try CmsParser.parseListing(text)
        if !listing.videos.isEmpty {
            return listing.videos
        }
        // Fallback for older CMS endpoints that only accept ac=list&wd=...
        let fallbackUrl = appendQuery(site.api, params: [("ac", "list"), ("wd", trimmed)])
        if let fbBytes = try? await fetchRawBytes(url: fallbackUrl, headers: site.headers, timeout: 8),
           let fbText = try? ConfigDecoder.decodeTextDocument(fbBytes),
           let fbListing = try? CmsParser.parseListing(fbText)
        {
            return fbListing.videos
        }
        return []
    }

    /// Concurrent multi-site global search using structured `withTaskGroup`.
    public func searchAllSites(
        sites: [CmsSite],
        keyword: String,
        maxSites: Int = 18,
        onBatch: (@Sendable (SiteSearchBatch) async -> Void)? = nil
    ) async -> [SiteSearchBatch] {
        let eligible = Array(
            sites.filter { $0.supported && $0.searchable && !$0.isBannerNoticeSite }.prefix(maxSites)
        )
        guard !eligible.isEmpty, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        return await withTaskGroup(of: SiteSearchBatch?.self) { group in
            for site in eligible {
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    guard let found = try? await self.searchSite(site: site, keyword: keyword), !found.isEmpty else {
                        return nil
                    }
                    return SiteSearchBatch(site: site, videos: found)
                }
            }
            var batches: [SiteSearchBatch] = []
            for await result in group {
                if let batch = result {
                    batches.append(batch)
                    await onBatch?(batch)
                }
            }
            return batches
        }
    }

    // MARK: - Playback Stream, Netdisk Share & Multi-Worker Range Proxy Resolution

    public func resolvePlayback(
        site: CmsSite,
        lineName: String = "",
        episode: CmsEpisode,
        parses: [CmsParse] = [],
        proxyServer: LocalHeaderProxyServer? = nil,
        storage: TvStorageManager? = nil,
        rangeProxyServer: NetdiskRangeProxyServer? = nil,
        isLiveStream: Bool = false
    ) async throws -> ResolvedPlayback {
        var resolvedUrlString = episode.url.trimmingCharacters(in: .whitespacesAndNewlines)
        var mergedHeaders = LiveCatalogParser.mergeHeaders([site.headers, episode.headers])

        if site.hasQuickJsAdapter && (!episode.isDirectPlayable || episode.isScriptEpisode) {
            if episode.isNetdiskUrl {
                if let host = try? await resolveJsHost(for: site),
                   let jsResult = try? await host.playerContent(flag: lineName, id: episode.url),
                   !jsResult.url.isEmpty
                {
                    resolvedUrlString = jsResult.url
                    mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, jsResult.headers])
                }
            } else {
                let host = try await resolveJsHost(for: site)
                let jsResult = try await host.playerContent(flag: lineName, id: episode.url)
                if !jsResult.url.isEmpty {
                    resolvedUrlString = jsResult.url
                    mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, jsResult.headers])
                }
            }
        }

        // Route Netdisk share pages and authenticated Netdisk streams through NetdiskShareResolver + RangeProxy
        if let storage = storage,
           NetdiskShareResolver.detectDriveKey(for: resolvedUrlString, lineName: lineName) != nil
        {
            let prefs = storage.preferences()
            return try await netdiskResolver.resolvePlayback(
                rawUrl: resolvedUrlString,
                lineName: lineName,
                extraHeaders: mergedHeaders,
                qualityPreference: prefs.netdiskQuality,
                playerKernel: prefs.playerKernel,
                storage: storage,
                rangeProxy: rangeProxyServer,
                headerProxy: proxyServer
            )
        }

        if !site.hasQuickJsAdapter && !episode.isDirectPlayable {
            // Try JSON parse endpoint (`site.playUrl` or `parses` with type 1)
            let parserCandidates: [String] = {
                var out: [String] = []
                if site.playUrl.lowercased().hasPrefix("http") {
                    out.append(site.playUrl)
                }
                for p in parses where p.type == 1 || p.type == 2 || p.type == 3 {
                    if !out.contains(p.url) { out.append(p.url) }
                }
                return out
            }()

            for parserBase in parserCandidates {
                let encodedTarget = resolvedUrlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedUrlString
                let fullParseUrl = parserBase + encodedTarget
                if let pBytes = try? await fetchRawBytes(url: fullParseUrl, headers: mergedHeaders, timeout: 10),
                   let pText = try? ConfigDecoder.decodeTextDocument(pBytes),
                   let json = (try? JSONSerialization.jsonObject(with: Data(ConfigDecoder.stripJsonComments(pText).utf8))) as? [String: Any],
                   let parsedMediaUrl = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   parsedMediaUrl.lowercased().hasPrefix("http")
                {
                    resolvedUrlString = parsedMediaUrl
                    if let extraH = json["header"] ?? json["headers"],
                       let hDict = extraH as? [String: Any]
                    {
                        var extraStrings: [String: String] = [:]
                        for (k, v) in hDict { extraStrings[k] = String(describing: v) }
                        mergedHeaders = LiveCatalogParser.mergeHeaders([mergedHeaders, extraStrings])
                    }
                    break
                }
            }
        }

        guard let finalUrl = URL(string: CmsParser.normalizeUrl(resolvedUrlString)) else {
            throw MarcoError.invalidFormat("无法解析播放流地址：\(resolvedUrlString)")
        }

        let badge = NetdiskShareResolver.inferResolutionBadge(from: finalUrl.absoluteString, fallbackQuality: "auto")
        let lowerExt = finalUrl.pathExtension.lowercased()
        let isDirectContainer = ["mkv", "mp4", "m4v", "mov"].contains(lowerExt)
        let preferredKernel = storage?.preferences().playerKernel ?? "range_proxy"

        if !isLiveStream, isDirectContainer, preferredKernel == "range_proxy", let rangeProxy = rangeProxyServer {
            let host = (finalUrl.host ?? "").lowercased()
            let isLoopback = (host == "127.0.0.1" || host == "localhost" || host == "::1")
            let policy = NetdiskHeaderPolicy(
                originUrl: finalUrl,
                baseHeaders: mergedHeaders,
                cookieDomains: [],
                allowInsecureLoopbackCredentials: isLoopback
            )
            let (resourceId, loopbackUrl) = try await rangeProxy.registerStream(url: finalUrl, policy: policy)
            return ResolvedPlayback(
                originalUrl: finalUrl.absoluteString,
                playableUrl: loopbackUrl,
                headers: mergedHeaders,
                isProxied: true,
                kernelLabel: "\(rangeProxy.workers) 线程分片代理",
                resolutionBadge: badge,
                rangeProxyResourceId: resourceId
            )
        }

        let needsHeaderProxy = !mergedHeaders.isEmpty
            && (finalUrl.scheme?.lowercased() == "http" || finalUrl.scheme?.lowercased() == "https")
        if needsHeaderProxy, let proxy = proxyServer {
            let (sessionId, loopbackUrl) = try await proxy.registerStreamWithId(url: finalUrl, headers: mergedHeaders)
            return ResolvedPlayback(
                originalUrl: finalUrl.absoluteString,
                playableUrl: loopbackUrl,
                headers: mergedHeaders,
                isProxied: true,
                kernelLabel: lowerExt == "m3u8" ? "HLS 代理硬解" : "AVKit 硬解",
                resolutionBadge: badge,
                headerProxySessionId: sessionId
            )
        }
        return ResolvedPlayback(
            originalUrl: finalUrl.absoluteString,
            playableUrl: finalUrl,
            headers: mergedHeaders,
            isProxied: false,
            kernelLabel: "AVKit 硬解",
            resolutionBadge: badge
        )
    }

    // MARK: - Internal Helpers

    private func withJsHostLock<T>(_ body: () -> T) -> T {
        jsHostCacheLock.lock()
        defer { jsHostCacheLock.unlock() }
        return body()
    }

    private func resolveJsHost(for site: CmsSite) async throws -> ScriptHostBackend {
        if let cached = withJsHostLock({ scriptHosts[site.key] }) {
            return cached
        }

        // 1. Guard-ported TVBox plugins (FTY / WEX / DM84 / Auete / Bttwoo / AppGZ / T4 / AppTT / FY)
        if let adapter = site.guardAdapterKey,
           let parsedRef = GuardPluginExtractor.parsePluginReference(site.pluginReference)
        {
            let jarBytes: Data
            if let cachedJar = withJsHostLock({ jarCache[parsedRef.url] }) {
                jarBytes = cachedJar
            } else {
                let downloaded = try await fetchRawBytes(url: parsedRef.url, headers: site.headers, timeout: 25)
                try GuardPluginExtractor.verifyOptionalMd5(data: downloaded, expectedMd5: parsedRef.expectedMd5)
                withJsHostLock {
                    if jarCache.count >= 6 {
                        jarCache.removeAll()
                    }
                    jarCache[parsedRef.url] = downloaded
                }
                jarBytes = downloaded
            }
            let rawExt = (site.rawExtension ?? site.ext).trimmingCharacters(in: .whitespacesAndNewlines)
            let extracted = try GuardPluginExtractor.extract(
                artifactBytes: jarBytes,
                adapter: adapter,
                extension: rawExt.isEmpty ? nil : rawExt
            )
            let drpyHost = try DrpySourceHost(
                site: site,
                ruleSource: extracted.rule,
                origin: extracted.origin
            )
            try await drpyHost.initialize()
            let backend = ScriptHostBackend.drpy(drpyHost)
            withJsHostLock { scriptHosts[site.key] = backend }
            return backend
        }

        // 2. Local or remote DRPY2 rules & CatVod/TVBox JS Spiders
        let scriptCode: String
        var scriptOrigin = site.api
        var localModules: [String: String] = [:]

        if site.api == "csp_LocalScript.js" || site.api == "csp_LocalRule.js" {
            if let extData = site.ext.data(using: .utf8),
               let extMap = (try? JSONSerialization.jsonObject(with: extData)) as? [String: Any],
               let inlineScript = extMap["script"] as? String,
               !inlineScript.isEmpty
            {
                scriptCode = inlineScript
                if let mods = extMap["modules"] as? [String: String] {
                    localModules = mods
                }
                if let orig = extMap["origin"] as? String, !orig.isEmpty {
                    scriptOrigin = orig
                } else {
                    scriptOrigin = "pkg://local/rule.js"
                }
            } else {
                scriptCode = site.ext
                scriptOrigin = "pkg://local/rule.js"
            }
        } else if site.isDrpySource && site.ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http") {
            let extUrl = site.ext.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = try await fetchRawBytes(url: extUrl, headers: site.headers)
            scriptCode = try ConfigDecoder.decodeTextDocument(bytes)
            scriptOrigin = extUrl
        } else if site.isDrpySource && !site.ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scriptCode = site.ext
            scriptOrigin = "pkg://local/rule.js"
        } else {
            let bytes = try await fetchRawBytes(url: site.api, headers: site.headers)
            scriptCode = try ConfigDecoder.decodeTextDocument(bytes)
            scriptOrigin = site.api
        }

        if site.isDrpySource || DrpySourceHost.looksLikeDrpyRule(scriptCode) {
            let drpyHost = try DrpySourceHost(
                site: site,
                ruleSource: scriptCode,
                origin: scriptOrigin,
                localModules: localModules
            )
            try await drpyHost.initialize()
            let backend = ScriptHostBackend.drpy(drpyHost)
            withJsHostLock { scriptHosts[site.key] = backend }
            return backend
        }

        let host = try JsSourceHost(site: site, scriptSource: scriptCode)
        try await host.initialize()
        let backend = ScriptHostBackend.spider(host)
        withJsHostLock { scriptHosts[site.key] = backend }
        return backend
    }

    private func appendQuery(_ baseUrl: String, params: [(String, String)]) -> String {
        let normalized = CmsParser.normalizeUrl(baseUrl)
        guard var comps = URLComponents(string: normalized) else { return normalized }
        var items = comps.queryItems ?? []
        let overridden = Set(params.map { $0.0.lowercased() })
        items.removeAll { overridden.contains($0.name.lowercased()) }
        for (k, v) in params {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        return comps.string ?? normalized
    }

    private func mergeVideoDetail(summary: CmsVideo, detail: CmsVideo) -> CmsVideo {
        CmsVideo(
            id: detail.id.isEmpty ? summary.id : detail.id,
            title: detail.title.isEmpty ? summary.title : detail.title,
            poster: detail.poster.isEmpty ? summary.poster : detail.poster,
            remarks: detail.remarks.isEmpty ? summary.remarks : detail.remarks,
            year: detail.year.isEmpty ? summary.year : detail.year,
            area: detail.area.isEmpty ? summary.area : detail.area,
            actor: detail.actor.isEmpty ? summary.actor : detail.actor,
            description: detail.description.isEmpty ? summary.description : detail.description,
            tag: detail.tag.isEmpty ? summary.tag : detail.tag,
            doubanScore: detail.doubanScore ?? summary.doubanScore,
            rtScore: detail.rtScore ?? summary.rtScore,
            lines: detail.lines.isEmpty ? summary.lines : detail.lines,
            sourceWarnings: detail.sourceWarnings.isEmpty ? summary.sourceWarnings : detail.sourceWarnings
        )
    }
}

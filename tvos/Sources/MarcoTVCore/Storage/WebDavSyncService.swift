// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public struct WebDavHttpResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

public protocol WebDavTransportProtocol: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse
}

public final class URLSessionWebDavTransport: WebDavTransportProtocol {
    private let session: URLSession

    public init(timeoutSeconds: TimeInterval = 15) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds * 2
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)
    }

    public func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        var outHeaders: [String: String] = [:]
        if let all = http?.allHeaderFields {
            for (rk, rv) in all {
                outHeaders[String(describing: rk)] = String(describing: rv)
            }
        }
        return WebDavHttpResponse(statusCode: http?.statusCode ?? 200, headers: outHeaders, body: data)
    }
}

public struct SyncMergeSummary: Equatable, Sendable {
    public var historyCount: Int
    public var favoriteCount: Int
    public var subscriptionCount: Int
    public var changed: Bool
    public var subscriptionsChanged: Bool
    public var payloadJson: String

    public init(
        historyCount: Int,
        favoriteCount: Int,
        subscriptionCount: Int,
        changed: Bool,
        subscriptionsChanged: Bool,
        payloadJson: String
    ) {
        self.historyCount = historyCount
        self.favoriteCount = favoriteCount
        self.subscriptionCount = subscriptionCount
        self.changed = changed
        self.subscriptionsChanged = subscriptionsChanged
        self.payloadJson = payloadJson
    }
}

/// WebDAV Cloud Sync v2 engine compatible with Android, iOS, macOS, and Windows:
/// - Exact `resolveWebdavFileUrl` normalization (including `jianguoyun.com` -> `/dav/MarcoMovie/marco-movie-sync.json`)
/// - Recursive `MKCOL` collection creation on `404` / `409`
/// - Optimistic `ETag` (`If-Match` / `If-None-Match: *`) concurrency with `412` retry
/// - Per-item timestamp + tombstone 3-way merge (`hist:`, `fav:`, `add:`, `sub:`)
public final class WebDavSyncService: @unchecked Sendable {
    public static let syncSchema = "marco-movie-sync"
    public static let syncVersion = 2
    public static let defaultSyncFileName = "marco-movie-sync.json"
    public static let maxSyncPayloadBytes = 8 * 1024 * 1024

    private let storage: TvStorageManager
    private let transport: WebDavTransportProtocol
    private let lock = NSLock()
    private var noConditionalWriteHosts = Set<String>()

    public init(
        storage: TvStorageManager,
        transport: WebDavTransportProtocol = URLSessionWebDavTransport()
    ) {
        self.storage = storage
        self.transport = transport
    }

    private func isConditionalWriteDisabled(for hostKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return noConditionalWriteHosts.contains(hostKey)
    }

    private func disableConditionalWrite(for hostKey: String) {
        lock.lock()
        noConditionalWriteHosts.insert(hostKey)
        lock.unlock()
    }

    // MARK: - Canonical URL & Identity Rules

    public static func resolveWebdavFileUrl(_ rawUrl: String) throws -> String {
        var trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MarcoError.invalidFormat("请填写 WebDAV 服务器地址")
        }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "%20")

        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = comps.host?.lowercased(),
              !host.isEmpty
        else {
            throw MarcoError.invalidFormat("仅支持 HTTP 或 HTTPS WebDAV 地址")
        }

        let path = comps.path
        if path.lowercased().hasSuffix(".json") {
            return trimmed
        }

        let isJianguoyun = host == "jianguoyun.com" || host.hasSuffix(".jianguoyun.com")
        if isJianguoyun && (path.isEmpty || path == "/") {
            return trimmed.hasSuffix("/")
                ? "\(trimmed)dav/MarcoMovie/\(defaultSyncFileName)"
                : "\(trimmed)/dav/MarcoMovie/\(defaultSyncFileName)"
        }
        if isJianguoyun && (path == "/dav" || path == "/dav/") {
            return trimmed.hasSuffix("/")
                ? "\(trimmed)MarcoMovie/\(defaultSyncFileName)"
                : "\(trimmed)/MarcoMovie/\(defaultSyncFileName)"
        }
        return trimmed.hasSuffix("/")
            ? "\(trimmed)\(defaultSyncFileName)"
            : "\(trimmed)/\(defaultSyncFileName)"
    }

    public static func canonicalSubscriptionSyncKey(
        url: String,
        rawContent: String,
        warehouseUrl: String = ""
    ) -> String {
        func isHttp(_ s: String) -> Bool {
            let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return l.hasPrefix("http://") || l.hasPrefix("https://")
        }
        let effectiveHttp = isHttp(warehouseUrl)
            ? warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            : (isHttp(url) ? url.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        let input = !effectiveHttp.isEmpty ? "url:\(effectiveHttp)" : "local:\(rawContent)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func baseCollectionDepth(rawBaseUrl: String, fileURL: URL) -> Int {
        let allSegs = fileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard allSegs.count > 1 else { return 0 }
        let parentSegs = Array(allSegs.dropLast())

        let baseSegs: [String] = {
            var t = rawBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return [] }
            if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") {
                t = "https://\(t)"
            }
            t = t.replacingOccurrences(of: " ", with: "%20")
            guard let u = URL(string: t), !u.path.lowercased().hasSuffix(".json") else { return [] }
            return u.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        }()

        func isPrefix(_ prefix: [String], of full: [String]) -> Bool {
            guard prefix.count <= full.count else { return false }
            return zip(prefix, full).allSatisfy { $0.lowercased() == $1.lowercased() }
        }

        let host = (fileURL.host ?? "").lowercased()
        let isJianguoyun = host == "jianguoyun.com" || host.hasSuffix(".jianguoyun.com")
        if isJianguoyun, parentSegs.first?.lowercased() == "dav" {
            var skip = 1
            if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
                skip = max(skip, baseSegs.count)
            }
            return skip
        }
        if parentSegs.count >= 4,
           parentSegs[0].lowercased() == "remote.php",
           parentSegs[1].lowercased() == "dav",
           parentSegs[2].lowercased() == "files"
        {
            var skip = 4
            if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
                skip = max(skip, baseSegs.count)
            }
            return skip
        }
        if !baseSegs.isEmpty && baseSegs.count < parentSegs.count && isPrefix(baseSegs, of: parentSegs) {
            return baseSegs.count
        }
        return 0
    }

    private struct ComputedSyncMerge {
        let summary: SyncMergeSummary
        let localSubscriptions: [SubscriptionEntry]
        let localWatchHistory: [WatchHistoryItem]
        let localFavorites: [FavoriteItem]
        let localTombstones: [String: Int64]
    }

    private static func isHistoryTombstone(_ key: String) -> Bool {
        key.hasPrefix("hist:") || key.hasPrefix("fav:") || key.hasPrefix("add:")
    }

    private static func isSubscriptionTombstone(_ key: String) -> Bool {
        key.hasPrefix("sub:")
    }

    private static func serializePublicSubscriptions(_ entries: [SubscriptionEntry]) -> [[String: Any]] {
        let pubSubs = entries.filter { !$0.isEffectivelyPrivate && !$0.rawContent.isEmpty }
        var subsPayload: [[String: Any]] = []
        var seenKeys = Set<String>()
        for s in pubSubs {
            let sk = Self.canonicalSubscriptionSyncKey(
                url: s.url,
                rawContent: s.rawContent,
                warehouseUrl: s.warehouseUrl
            )
            guard seenKeys.insert(sk).inserted else { continue }
            var dict = s.toDictionary()
            dict["syncKey"] = sk
            dict["isPrivate"] = false
            if s.updatedAt <= 0 { dict["updatedAt"] = Int64(1) }
            subsPayload.append(dict)
        }
        return subsPayload
    }

    private static func encodeSyncPayloadObject(
        nowMs: Int64,
        watchHistory: [[String: Any]],
        favorites: [[String: Any]],
        tombstones: [String: Int64],
        subscriptions: [[String: Any]]?
    ) throws -> String {
        var root: [String: Any] = [
            "schema": Self.syncSchema,
            "version": Self.syncVersion,
            "updated": nowMs,
            "watch_history": watchHistory,
            "favorites": favorites,
            "tombstones": tombstones,
        ]
        if let subs = subscriptions {
            root["subscriptions"] = subs
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Sync Payload Export & 3-Way Timestamp Merge

    public func exportSyncPayload(
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> String {
        let hist = syncHistory ? storage.watchHistory().map { $0.toDictionary() } : []
        let localFavs = syncHistory ? storage.favorites() : []
        let favs = localFavs.map { $0.toDictionary() }

        let rawTombs = storage.tombstones()
        var tombs: [String: Int64] = [:]
        for (k, v) in rawTombs {
            if Self.isHistoryTombstone(k) {
                if syncHistory { tombs[k] = v }
            } else if Self.isSubscriptionTombstone(k) {
                if syncSubscriptions { tombs[k] = v }
            } else {
                tombs[k] = v
            }
        }
        if syncHistory {
            for f in localFavs where f.updated > 0 {
                let addKey = "add:\(f.key)"
                let prev = tombs[addKey] ?? 0
                if f.updated > prev { tombs[addKey] = f.updated }
            }
        }

        let subsPayload: [[String: Any]]? = syncSubscriptions
            ? Self.serializePublicSubscriptions(storage.subscriptions())
            : nil

        return try Self.encodeSyncPayloadObject(
            nowMs: nowMs,
            watchHistory: hist,
            favorites: favs,
            tombstones: tombs,
            subscriptions: subsPayload
        )
    }

    public func mergeSyncPayload(
        _ remotePayloadRaw: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> SyncMergeSummary {
        let computed = try computeMergedSyncState(
            remotePayloadRaw,
            nowMs: nowMs,
            syncSubscriptions: syncSubscriptions,
            syncHistory: syncHistory
        )
        if syncSubscriptions || syncHistory {
            storage.applyMergedSyncState(
                subscriptions: computed.localSubscriptions,
                watchHistory: computed.localWatchHistory,
                favorites: computed.localFavorites,
                tombstones: computed.localTombstones
            )
        }
        return computed.summary
    }

    private func computeMergedSyncState(
        _ remotePayloadRaw: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true
    ) throws -> ComputedSyncMerge {
        let localSubsAll = storage.subscriptions()
        let localHist = storage.watchHistory()
        let localFavs = storage.favorites()
        let localTombsRaw = storage.tombstones()

        guard let remoteRaw = remotePayloadRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteRaw.isEmpty
        else {
            let payload = try exportSyncPayload(
                nowMs: nowMs,
                syncSubscriptions: syncSubscriptions,
                syncHistory: syncHistory
            )
            var nextLocalTombs = localTombsRaw
            if syncHistory {
                for f in localFavs where f.updated > 0 {
                    let addKey = "add:\(f.key)"
                    if f.updated > (nextLocalTombs[addKey] ?? 0) {
                        nextLocalTombs[addKey] = f.updated
                    }
                }
            }
            let summary = SyncMergeSummary(
                historyCount: localHist.count,
                favoriteCount: localFavs.count,
                subscriptionCount: localSubsAll.filter { !$0.isEffectivelyPrivate }.count,
                changed: false,
                subscriptionsChanged: false,
                payloadJson: payload
            )
            return ComputedSyncMerge(
                summary: summary,
                localSubscriptions: localSubsAll,
                localWatchHistory: localHist,
                localFavorites: localFavs,
                localTombstones: nextLocalTombs
            )
        }

        if remoteRaw.utf8.count > Self.maxSyncPayloadBytes {
            throw MarcoError.invalidFormat("远端同步文件超过 8 MB 大小限制")
        }

        let cleanedRemote = ConfigDecoder.stripJsonComments(remoteRaw)
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(cleanedRemote.utf8))) as? [String: Any] else {
            throw MarcoError.invalidFormat("远端同步数据不是有效的 JSON 格式")
        }

        let schema = (decoded["schema"] as? String) ?? ""
        let format = (decoded["format"] as? String) ?? ""
        var remoteHist: [WatchHistoryItem] = []
        var remoteHistRaw: [[String: Any]] = []
        var remoteFavs: [FavoriteItem] = []
        var remoteFavsRaw: [[String: Any]] = []
        var remoteTombsRaw: [String: Int64] = [:]
        var remoteFavAddTombs: [String: Int64] = [:]
        var remoteSubsRaw: [[String: Any]]? = nil

        if schema == Self.syncSchema {
            if let rh = (decoded["watch_history"] ?? decoded["history"] ?? decoded["watchHistory"]) as? [Any] {
                for item in rh {
                    guard let map = item as? [String: Any] else { continue }
                    remoteHistRaw.append(map)
                    let entry = WatchHistoryItem.fromDictionary(map)
                    if !entry.site.isEmpty && !entry.id.isEmpty {
                        remoteHist.append(entry)
                    }
                }
            }
            if let rf = decoded["favorites"] as? [Any] {
                for item in rf {
                    guard let map = item as? [String: Any] else { continue }
                    remoteFavsRaw.append(map)
                    let fav = FavoriteItem.fromDictionary(map)
                    if !fav.site.isEmpty && !fav.id.isEmpty {
                        remoteFavs.append(fav)
                        if fav.updated > 0 {
                            let addKey = "add:\(fav.key)"
                            if fav.updated > (remoteFavAddTombs[addKey] ?? 0) {
                                remoteFavAddTombs[addKey] = fav.updated
                            }
                        }
                    }
                }
            }
            if let rs = decoded["subscriptions"] as? [Any] {
                remoteSubsRaw = rs.compactMap { $0 as? [String: Any] }
            }
            if let rt = decoded["tombstones"] as? [String: Any] {
                for (k, v) in rt {
                    if let num = v as? NSNumber, num.int64Value > 0, !k.isEmpty {
                        remoteTombsRaw[k] = num.int64Value
                    }
                }
            }
        } else if format == BackupPayload.backupFormat || schema == BackupPayload.backupSchema {
            let backup = try BackupCodec.decodeBackupJson(remoteRaw)
            remoteHist = backup.watchHistory
            remoteHistRaw = backup.watchHistory.map { $0.toDictionary() }
            remoteFavs = backup.favorites
            remoteFavsRaw = backup.favorites.map { $0.toDictionary() }
            for fav in remoteFavs where fav.updated > 0 {
                let addKey = "add:\(fav.key)"
                if fav.updated > (remoteFavAddTombs[addKey] ?? 0) {
                    remoteFavAddTombs[addKey] = fav.updated
                }
            }
            remoteSubsRaw = backup.subscriptions.map { $0.toDictionary() }
        } else {
            throw MarcoError.invalidFormat("远端同步文件格式不受支持")
        }

        // Partition tombstones strictly by category so disabled sync switches NEVER modify local
        // OR remote data/tombstones for the unsubscribed category.
        var localHistTombs = localTombsRaw.filter { Self.isHistoryTombstone($0.key) }
        var localSubTombs = localTombsRaw.filter { Self.isSubscriptionTombstone($0.key) }
        let localOtherTombs = localTombsRaw.filter { !Self.isHistoryTombstone($0.key) && !Self.isSubscriptionTombstone($0.key) }

        let remoteHistTombsRaw = remoteTombsRaw.filter { Self.isHistoryTombstone($0.key) }
        let remoteSubTombsRaw = remoteTombsRaw.filter { Self.isSubscriptionTombstone($0.key) }
        let remoteOtherTombsRaw = remoteTombsRaw.filter { !Self.isHistoryTombstone($0.key) && !Self.isSubscriptionTombstone($0.key) }

        // 1. Subscriptions & sub: tombstones
        var finalSubscriptions = localSubsAll
        var subscriptionsChanged = false
        let outboundSubscriptions: [[String: Any]]?
        let outboundSubTombs: [String: Int64]

        if syncSubscriptions {
            var mergedSubTombs = localSubTombs
            for (k, ts) in remoteSubTombsRaw where ts > (mergedSubTombs[k] ?? 0) {
                mergedSubTombs[k] = ts
            }

            let localPrivate = localSubsAll.filter { $0.isEffectivelyPrivate }
            let localPublic = localSubsAll.filter { !$0.isEffectivelyPrivate }
            var subOrder: [String] = []
            var subByKey: [String: SubscriptionEntry] = [:]
            var reservedIds = Set(localPrivate.map(\.id))

            for s in localPublic where !s.rawContent.isEmpty {
                let sk = Self.canonicalSubscriptionSyncKey(url: s.url, rawContent: s.rawContent, warehouseUrl: s.warehouseUrl)
                let delTs = mergedSubTombs["sub:\(sk)"] ?? 0
                if delTs > 0 {
                    if s.updatedAt > delTs {
                        mergedSubTombs.removeValue(forKey: "sub:\(sk)")
                    } else {
                        continue
                    }
                }
                if subByKey[sk] == nil { subOrder.append(sk) }
                subByKey[sk] = s
                reservedIds.insert(s.id)
            }

            for rawMap in (remoteSubsRaw ?? []) {
                let candidate = SubscriptionEntry.fromDictionary(rawMap)
                guard !candidate.isEffectivelyPrivate,
                      !candidate.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parsed = try? CmsParser.parseConfig(candidate.rawContent, origin: candidate.url)
                else {
                    continue
                }
                let sk = Self.canonicalSubscriptionSyncKey(
                    url: candidate.url,
                    rawContent: candidate.rawContent,
                    warehouseUrl: candidate.warehouseUrl
                )
                let incomingTs = max(1, candidate.updatedAt)
                let delTs = mergedSubTombs["sub:\(sk)"] ?? 0
                if delTs > 0 {
                    if incomingTs > delTs {
                        mergedSubTombs.removeValue(forKey: "sub:\(sk)")
                    } else {
                        continue
                    }
                }

                if let existing = subByKey[sk] {
                    if incomingTs > existing.updatedAt {
                        var updated = candidate
                        updated.id = existing.id
                        updated.siteCount = parsed.sites.count
                        updated.liveCount = parsed.lives.count
                        updated.updatedAt = incomingTs
                        subByKey[sk] = updated
                    }
                } else {
                    var assignedId = candidate.id
                    if assignedId.isEmpty || reservedIds.contains(assignedId) {
                        assignedId = "sub_\(sk.prefix(10))"
                    }
                    reservedIds.insert(assignedId)
                    var inserted = candidate
                    inserted.id = assignedId
                    inserted.siteCount = parsed.sites.count
                    inserted.liveCount = parsed.lives.count
                    inserted.updatedAt = incomingTs
                    if inserted.depots.isEmpty { inserted.depots = parsed.depots }
                    subOrder.append(sk)
                    subByKey[sk] = inserted
                }
            }

            let mergedPublic = subOrder.compactMap { subByKey[$0] }
            subscriptionsChanged = mergedPublic != localPublic
            finalSubscriptions = mergedPublic + localPrivate
            localSubTombs = mergedSubTombs
            outboundSubscriptions = Self.serializePublicSubscriptions(mergedPublic)
            outboundSubTombs = mergedSubTombs
        } else {
            // Preserve BOTH local subscriptions/tombstones AND remote subscriptions/tombstones untouched.
            outboundSubscriptions = remoteSubsRaw
            outboundSubTombs = remoteSubTombsRaw
        }

        // 2. Watch history, favorites & hist:/fav:/add: tombstones
        var finalHistory = localHist
        var finalFavorites = localFavs
        let outboundWatchHistory: [[String: Any]]
        let outboundFavorites: [[String: Any]]
        let outboundHistTombs: [String: Int64]

        if syncHistory {
            var mergedHistTombs = localHistTombs
            for f in localFavs where f.updated > 0 {
                let addKey = "add:\(f.key)"
                if f.updated > (mergedHistTombs[addKey] ?? 0) {
                    mergedHistTombs[addKey] = f.updated
                }
            }
            for (k, ts) in remoteHistTombsRaw where ts > (mergedHistTombs[k] ?? 0) {
                mergedHistTombs[k] = ts
            }
            for (k, ts) in remoteFavAddTombs where ts > (mergedHistTombs[k] ?? 0) {
                mergedHistTombs[k] = ts
            }
            for k in Array(mergedHistTombs.keys) where k.hasPrefix("fav:") {
                let rawKey = String(k.dropFirst(4))
                if let delTs = mergedHistTombs[k], let addTs = mergedHistTombs["add:\(rawKey)"] {
                    if addTs > delTs {
                        mergedHistTombs.removeValue(forKey: k)
                    } else {
                        mergedHistTombs.removeValue(forKey: "add:\(rawKey)")
                    }
                }
            }

            var histByKey: [String: WatchHistoryItem] = [:]
            for e in (localHist + remoteHist) {
                let delTs = mergedHistTombs["hist:\(e.key)"] ?? 0
                if delTs > 0 {
                    if e.updated > delTs {
                        mergedHistTombs.removeValue(forKey: "hist:\(e.key)")
                    } else {
                        continue
                    }
                }
                if let existing = histByKey[e.key] {
                    if e.updated > existing.updated || (e.updated == existing.updated && e.position > existing.position) {
                        histByKey[e.key] = e
                    }
                } else {
                    histByKey[e.key] = e
                }
            }
            finalHistory = Array(
                histByKey.values
                    .sorted { a, b in
                        if a.updated != b.updated { return a.updated > b.updated }
                        return a.key < b.key
                    }
                    .prefix(CmsParser.maxHistoryEntries)
            )

            var favByKey: [String: FavoriteItem] = [:]
            for f in (localFavs + remoteFavs) {
                let delTs = mergedHistTombs["fav:\(f.key)"] ?? 0
                let addTs = mergedHistTombs["add:\(f.key)"] ?? f.updated
                if delTs > 0 && delTs >= addTs {
                    continue
                }
                if let existing = favByKey[f.key] {
                    if f.updated > existing.updated {
                        var nextFav = f
                        if addTs > nextFav.updated { nextFav.updated = addTs }
                        favByKey[f.key] = nextFav
                    }
                } else {
                    var nextFav = f
                    if addTs > nextFav.updated { nextFav.updated = addTs }
                    favByKey[f.key] = nextFav
                }
            }
            finalFavorites = Array(
                favByKey.values
                    .sorted { a, b in
                        let ta = mergedHistTombs["add:\(a.key)"] ?? a.updated
                        let tb = mergedHistTombs["add:\(b.key)"] ?? b.updated
                        if ta != tb { return ta > tb }
                        return a.key < b.key
                    }
                    .prefix(CmsParser.maxFavoriteEntries)
            )

            for f in finalFavorites where f.updated > 0 {
                let addKey = "add:\(f.key)"
                if f.updated > (mergedHistTombs[addKey] ?? 0) {
                    mergedHistTombs[addKey] = f.updated
                }
            }

            localHistTombs = mergedHistTombs
            outboundWatchHistory = finalHistory.map { $0.toDictionary() }
            outboundFavorites = finalFavorites.map { $0.toDictionary() }
            outboundHistTombs = mergedHistTombs
        } else {
            // Preserve BOTH local history/favorites/tombstones AND remote history/favorites/tombstones untouched.
            outboundWatchHistory = remoteHistRaw
            outboundFavorites = remoteFavsRaw
            outboundHistTombs = remoteHistTombsRaw
        }

        var localMergedTombs = localOtherTombs
        for (k, v) in localHistTombs { localMergedTombs[k] = v }
        for (k, v) in localSubTombs { localMergedTombs[k] = v }

        var outboundTombs = remoteOtherTombsRaw
        for (k, v) in outboundHistTombs { outboundTombs[k] = v }
        for (k, v) in outboundSubTombs { outboundTombs[k] = v }

        let payloadJson = try Self.encodeSyncPayloadObject(
            nowMs: nowMs,
            watchHistory: outboundWatchHistory,
            favorites: outboundFavorites,
            tombstones: outboundTombs,
            subscriptions: outboundSubscriptions
        )

        let changed = subscriptionsChanged
            || finalHistory != localHist
            || finalFavorites != localFavs
            || localMergedTombs != localTombsRaw

        let summary = SyncMergeSummary(
            historyCount: finalHistory.count,
            favoriteCount: finalFavorites.count,
            subscriptionCount: finalSubscriptions.filter { !$0.isEffectivelyPrivate }.count,
            changed: changed,
            subscriptionsChanged: subscriptionsChanged,
            payloadJson: payloadJson
        )
        return ComputedSyncMerge(
            summary: summary,
            localSubscriptions: finalSubscriptions,
            localWatchHistory: finalHistory,
            localFavorites: finalFavorites,
            localTombstones: localMergedTombs
        )
    }

    // MARK: - Full WebDAV GET -> Merge -> MKCOL -> Conditional PUT Cycle

    public func syncNow(maxConflictRetries: Int = 3) async throws -> SyncMergeSummary {
        var config = storage.loadWebDavConfig()
        let rawBaseUrl = config.url
        let targetUrlStr = try Self.resolveWebdavFileUrl(rawBaseUrl)
        guard let fileURL = URL(string: targetUrlStr) else {
            throw MarcoError.invalidFormat("无效的 WebDAV 目标地址")
        }

        let hostKey = "\(fileURL.scheme?.lowercased() ?? "https")://\(fileURL.host?.lowercased() ?? ""):\(fileURL.port ?? 443)"
        let boundedRetries = max(0, min(maxConflictRetries, 8))
        var attempt = 0

        do {
            while true {
                var remoteBody: String?
                var remoteEtag: String?
                var fileAbsent = false

                let getResp = try await transport.send(
                    method: "GET",
                    url: fileURL,
                    headers: buildHeaders(config: config),
                    body: nil
                )
                if (200...299).contains(getResp.statusCode) {
                    if getResp.body.count > Self.maxSyncPayloadBytes {
                        throw MarcoError.webdavError("远端同步文件超过 8 MB 限制")
                    }
                    remoteBody = String(decoding: getResp.body, as: UTF8.self)
                    if let etag = getResp.header("ETag")?.trimmingCharacters(in: .whitespaces),
                       !etag.isEmpty,
                       !etag.lowercased().hasPrefix("w/")
                    {
                        remoteEtag = etag
                    }
                } else if getResp.statusCode == 404 {
                    remoteBody = nil
                    fileAbsent = true
                } else if getResp.statusCode == 401 || getResp.statusCode == 403 {
                    throw MarcoError.webdavError("WebDAV 认证失败 (HTTP \(getResp.statusCode))，请检查账号与应用密码")
                } else {
                    throw MarcoError.webdavError("WebDAV 读取失败 (HTTP \(getResp.statusCode))")
                }

                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let computed = try computeMergedSyncState(
                    remoteBody,
                    nowMs: nowMs,
                    syncSubscriptions: config.syncSubscriptions,
                    syncHistory: config.syncHistory
                )

                // If both sync toggles are off, preserve both local and remote without issuing a PUT.
                if !config.syncSubscriptions && !config.syncHistory {
                    config.lastSyncTimeMs = nowMs
                    config.lastSyncStatus = "未开启任何同步项，已保留本机与远端数据"
                    try? storage.saveWebDavConfig(config)
                    return computed.summary
                }

                let payloadBytes = Data(computed.summary.payloadJson.utf8)
                let skipCond = isConditionalWriteDisabled(for: hostKey)

                var ifMatch: String?
                var ifNoneMatch: String?
                if !skipCond {
                    if fileAbsent {
                        ifNoneMatch = "*"
                    } else if let etag = remoteEtag {
                        ifMatch = etag
                    }
                }

                var putResp = try await putWithMkcolRetry(
                    config: config,
                    rawBaseUrl: rawBaseUrl,
                    fileURL: fileURL,
                    payload: payloadBytes,
                    ifMatch: ifMatch,
                    ifNoneMatch: ifNoneMatch
                )

                if ifNoneMatch != nil && [400, 405, 406, 417, 428, 500, 501].contains(putResp.statusCode) {
                    let retry = try await putWithMkcolRetry(
                        config: config,
                        rawBaseUrl: rawBaseUrl,
                        fileURL: fileURL,
                        payload: payloadBytes,
                        ifMatch: nil,
                        ifNoneMatch: nil
                    )
                    if (200...299).contains(retry.statusCode) {
                        disableConditionalWrite(for: hostKey)
                    }
                    putResp = retry
                }

                if putResp.statusCode == 412 {
                    if attempt < boundedRetries {
                        attempt += 1
                        continue
                    }
                    // Exhausted bounded retries: NEVER force-overwrite remote; preserve both ends and report conflict.
                    throw MarcoError.webdavError("WebDAV 远端持续冲突（HTTP 412），已保留本机与远端数据，请稍后重试")
                }

                if putResp.statusCode == 401 || putResp.statusCode == 403 {
                    throw MarcoError.webdavError("WebDAV 写入被拒绝 (HTTP \(putResp.statusCode))")
                }
                guard (200...299).contains(putResp.statusCode) else {
                    throw MarcoError.webdavError("WebDAV 写入失败 (HTTP \(putResp.statusCode))")
                }

                // Persist merged state locally only after conditional PUT succeeds.
                storage.applyMergedSyncState(
                    subscriptions: computed.localSubscriptions,
                    watchHistory: computed.localWatchHistory,
                    favorites: computed.localFavorites,
                    tombstones: computed.localTombstones
                )

                config.lastSyncTimeMs = nowMs
                config.lastSyncStatus = "同步成功（历史 \(computed.summary.historyCount) · 收藏 \(computed.summary.favoriteCount) · 订阅 \(computed.summary.subscriptionCount)）"
                try? storage.saveWebDavConfig(config)
                return computed.summary
            }
        } catch {
            config.lastSyncStatus = "同步失败：\(error.localizedDescription)"
            try? storage.saveWebDavConfig(config)
            throw error
        }
    }

    private func putWithMkcolRetry(
        config: WebDavConfig,
        rawBaseUrl: String,
        fileURL: URL,
        payload: Data,
        ifMatch: String?,
        ifNoneMatch: String?
    ) async throws -> WebDavHttpResponse {
        var resp = try await transport.send(
            method: "PUT",
            url: fileURL,
            headers: buildHeaders(config: config, jsonContent: true, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch),
            body: payload
        )
        if resp.statusCode == 404 || resp.statusCode == 409 {
            await ensureCollections(config: config, rawBaseUrl: rawBaseUrl, fileURL: fileURL)
            resp = try await transport.send(
                method: "PUT",
                url: fileURL,
                headers: buildHeaders(config: config, jsonContent: true, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch),
                body: payload
            )
        }
        return resp
    }

    private func ensureCollections(config: WebDavConfig, rawBaseUrl: String, fileURL: URL) async {
        let segs = fileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segs.count > 1 else { return }
        let skip = Self.baseCollectionDepth(rawBaseUrl: rawBaseUrl, fileURL: fileURL)
        guard var comps = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return }

        for i in skip..<(segs.count - 1) {
            let prefixPath = "/" + segs[0...i].joined(separator: "/") + "/"
            comps.path = prefixPath
            guard let collUrl = comps.url else { continue }
            if let mkResp = try? await transport.send(
                method: "MKCOL",
                url: collUrl,
                headers: buildHeaders(config: config),
                body: nil
            ), mkResp.statusCode == 401 {
                break
            }
        }
    }

    private func buildHeaders(
        config: WebDavConfig,
        jsonContent: Bool = false,
        ifMatch: String? = nil,
        ifNoneMatch: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Cache-Control": "no-store",
        ]
        if jsonContent {
            headers["Content-Type"] = "application/json; charset=utf-8"
        }
        if let im = ifMatch, !im.isEmpty {
            headers["If-Match"] = im
        }
        if let inm = ifNoneMatch, !inm.isEmpty {
            headers["If-None-Match"] = inm
        }
        if !config.username.isEmpty || !config.password.isEmpty {
            let basic = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(basic)"
        }
        return headers
    }
}

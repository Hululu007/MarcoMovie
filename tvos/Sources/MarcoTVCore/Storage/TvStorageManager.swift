// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import Security

public protocol KeychainStoreProtocol: Sendable {
    func setData(_ data: Data, forAccount account: String) throws
    func data(forAccount account: String) throws -> Data?
    func removeData(forAccount account: String) throws
}

/// System Keychain store backed by `Security` (`kSecClassGenericPassword`).
public final class SystemKeychainStore: KeychainStoreProtocol {
    public let service: String

    public init(service: String = "com.pilipala.marcoMovie.tv") {
        self.service = service
    }

    public func setData(_ data: Data, forAccount account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var insertQuery = baseQuery
            for (k, v) in attributesToUpdate { insertQuery[k] = v }
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MarcoError.storageError("Keychain write failed (\(addStatus))")
            }
            return
        }
        throw MarcoError.storageError("Keychain update failed (\(updateStatus))")
    }

    public func data(forAccount account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MarcoError.storageError("Keychain read failed (\(status))")
        }
        return result as? Data
    }

    public func removeData(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MarcoError.storageError("Keychain delete failed (\(status))")
        }
    }
}

/// Deterministic in-memory Keychain double for isolated CI and unit tests.
public final class InMemoryKeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    public init() {}

    public func setData(_ data: Data, forAccount account: String) throws {
        lock.lock()
        records[account] = data
        lock.unlock()
    }

    public func data(forAccount account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return records[account]
    }

    public func removeData(forAccount account: String) throws {
        lock.lock()
        records.removeValue(forKey: account)
        lock.unlock()
    }
}

/// Lossless `marco-movie-backup` (`MarcoMovie-1`) serializer interoperable with Android & Flutter.
public enum BackupCodec {
    public static let keySubscriptions = "saved_subscriptions"
    public static let keyWatchHistory = "watch_history"
    public static let keyFavorites = "favorites"
    public static let keySearchHistory = "global_search_history"
    public static let keySkipIntroSec = "skip_intro_sec"
    public static let keySkipOutroSec = "skip_outro_sec"
    public static let keyPlaySpeed = "play_speed"
    public static let keyAutoNext = "auto_next"
    public static let keyEpisodesDescending = "episodes_descending"
    public static let keyRepeatMode = "repeat_mode"
    public static let keySelectedSite = "selected_site"
    public static let keyPreferredSite = "preferred_site"

    public static func encodeBackupJson(_ payload: BackupPayload) throws -> String {
        let publicSubs = payload.subscriptions.filter { !$0.isEffectivelyPrivate }
        let primaryOrigin = !payload.origin.isEmpty ? payload.origin : (publicSubs.first?.url ?? "")
        let primaryRawConfig = !payload.rawConfig.isEmpty ? payload.rawConfig : (publicSubs.first?.rawContent ?? "")

        let configField: Any = {
            let trimmed = primaryRawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return NSNull() }
            let cleaned = ConfigDecoder.stripJsonComments(ConfigDecoder.unpackConfigText(trimmed))
            if let jsonObj = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) {
                return jsonObj
            }
            return trimmed
        }()

        let histJson = try stringifyJsonArray(payload.watchHistory.map { $0.toDictionary() })
        let favJson = try stringifyJsonArray(payload.favorites.map { $0.toDictionary() })
        let searchJson = try stringifyJsonArray(payload.searchHistory)

        var settings: [String: Any] = [
            keyWatchHistory: histJson,
            keyFavorites: favJson,
            keySearchHistory: searchJson,
            keySkipIntroSec: payload.preferences.skipIntroSec,
            keySkipOutroSec: payload.preferences.skipOutroSec,
            keyPlaySpeed: payload.preferences.playSpeed,
            keyAutoNext: payload.preferences.autoNext,
            keyEpisodesDescending: payload.preferences.episodesDescending,
            keyRepeatMode: payload.preferences.repeatMode,
            keySelectedSite: payload.preferences.selectedSiteKey,
            keyPreferredSite: payload.preferences.preferredSiteKey,
        ]
        if !publicSubs.isEmpty {
            settings[keySubscriptions] = publicSubs.map { $0.toDictionary() }
        }

        let root: [String: Any] = [
            "format": BackupPayload.backupFormat,
            "schema": BackupPayload.backupSchema,
            "version": BackupPayload.currentVersion,
            "exportedAt": payload.exportedAt,
            "origin": primaryOrigin,
            "config": configField,
            "settings": settings,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func isBackupPayload(_ rawText: String) -> Bool {
        let cleaned = ConfigDecoder.stripJsonComments(rawText)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            return false
        }
        return (obj["format"] as? String) == BackupPayload.backupFormat
            || (obj["schema"] as? String) == BackupPayload.backupSchema
    }

    public static func decodeBackupJson(_ rawBackup: String) throws -> BackupPayload {
        let cleaned = ConfigDecoder.stripJsonComments(rawBackup)
        guard let decoded = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            throw MarcoError.invalidFormat("不是有效的 Marco Movie 备份文件")
        }
        let fmt = (decoded["format"] as? String) ?? ""
        let sch = (decoded["schema"] as? String) ?? ""
        guard fmt == BackupPayload.backupFormat || sch == BackupPayload.backupSchema else {
            throw MarcoError.invalidFormat("不是有效的 Marco Movie 备份文件")
        }

        let origin = ((decoded["origin"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let exportedAt = (decoded["exportedAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)

        let rawConfigText: String
        if let rawField = decoded["config"], !(rawField is NSNull) {
            if let s = rawField as? String {
                rawConfigText = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if JSONSerialization.isValidJSONObject(rawField),
                      let d = try? JSONSerialization.data(withJSONObject: rawField)
            {
                rawConfigText = String(decoding: d, as: UTF8.self)
            } else {
                throw MarcoError.invalidFormat("备份中的配置字段格式无效")
            }
        } else {
            rawConfigText = ""
        }

        if !rawConfigText.isEmpty {
            _ = try CmsParser.parseConfig(rawConfigText, origin: origin)
        }

        let settings = (decoded["settings"] as? [String: Any]) ?? [:]
        let watchHistory = try parseRecordList(settings[keyWatchHistory]).map { dict -> WatchHistoryItem in
            try validateMediaRecord(dict)
            return WatchHistoryItem.fromDictionary(dict)
        }
        let favorites = try parseRecordList(settings[keyFavorites]).map { dict -> FavoriteItem in
            try validateMediaRecord(dict)
            return FavoriteItem.fromDictionary(dict)
        }
        let searchHistory = try parseStringList(settings[keySearchHistory])

        var subscriptions: [SubscriptionEntry] = []
        if let rawSubs = settings[keySubscriptions], !(rawSubs is NSNull) {
            guard let subArr = rawSubs as? [Any] else {
                throw MarcoError.invalidFormat("订阅列表格式无效")
            }
            var seenIds = Set<String>()
            for item in subArr {
                guard let map = item as? [String: Any] else {
                    throw MarcoError.invalidFormat("订阅条目格式无效")
                }
                let sub = SubscriptionEntry.fromDictionary(map)
                if sub.id.isEmpty || !seenIds.insert(sub.id).inserted || sub.isEffectivelyPrivate || sub.rawContent.isEmpty {
                    throw MarcoError.invalidFormat("常规备份包含无效订阅")
                }
                _ = try CmsParser.parseConfig(sub.rawContent, origin: sub.url)
                subscriptions.append(sub)
            }
        } else if !rawConfigText.isEmpty {
            let parsed = try CmsParser.parseConfig(rawConfigText, origin: origin)
            subscriptions.append(
                SubscriptionEntry(
                    id: "restored_primary",
                    name: "已恢复的订阅",
                    url: origin,
                    rawContent: rawConfigText,
                    siteCount: parsed.sites.count,
                    liveCount: parsed.lives.count,
                    updatedAt: exportedAt,
                    depots: parsed.depots
                )
            )
        }

        let prefs = PlaybackPreferences(
            skipIntroSec: (settings[keySkipIntroSec] as? NSNumber)?.intValue ?? 0,
            skipOutroSec: (settings[keySkipOutroSec] as? NSNumber)?.intValue ?? 0,
            playSpeed: (settings[keyPlaySpeed] as? NSNumber)?.doubleValue ?? 1.0,
            autoNext: (settings[keyAutoNext] as? Bool) ?? true,
            episodesDescending: (settings[keyEpisodesDescending] as? Bool) ?? false,
            repeatMode: (settings[keyRepeatMode] as? String) ?? "off",
            selectedSiteKey: (settings[keySelectedSite] as? String) ?? "",
            preferredSiteKey: (settings[keyPreferredSite] as? String) ?? ""
        )

        return BackupPayload(
            format: fmt.isEmpty ? BackupPayload.backupFormat : fmt,
            schema: sch.isEmpty ? BackupPayload.backupSchema : sch,
            version: (decoded["version"] as? NSNumber)?.intValue ?? BackupPayload.currentVersion,
            exportedAt: exportedAt,
            origin: origin,
            rawConfig: rawConfigText,
            subscriptions: subscriptions,
            watchHistory: watchHistory,
            favorites: favorites,
            searchHistory: searchHistory,
            preferences: prefs
        )
    }

    private static func stringifyJsonArray(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseRecordList(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw = raw, !(raw is NSNull) else { return [] }
        let decoded: Any
        if let s = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else {
                throw MarcoError.invalidFormat("备份记录 JSON 格式无效")
            }
            decoded = parsed
        } else {
            decoded = raw
        }
        guard let list = decoded as? [Any] else {
            throw MarcoError.invalidFormat("备份记录必须是列表")
        }
        return try list.map { elem in
            guard let dict = elem as? [String: Any] else {
                throw MarcoError.invalidFormat("备份记录条目格式无效")
            }
            return dict
        }
    }

    private static func parseStringList(_ raw: Any?) throws -> [String] {
        guard let raw = raw, !(raw is NSNull) else { return [] }
        let decoded: Any
        if let s = raw as? String {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) else {
                throw MarcoError.invalidFormat("搜索记录 JSON 格式无效")
            }
            decoded = parsed
        } else {
            decoded = raw
        }
        guard let list = decoded as? [Any] else {
            throw MarcoError.invalidFormat("搜索记录必须是列表")
        }
        return try list.map { elem in
            guard let str = elem as? String else {
                throw MarcoError.invalidFormat("搜索记录格式无效")
            }
            return str
        }
    }

    private static func validateMediaRecord(_ dict: [String: Any]) throws {
        guard let site = dict["site"] as? String, !site.isEmpty,
              let id = dict["id"] as? String, !id.isEmpty
        else {
            throw MarcoError.invalidFormat("观看记录或收藏缺少来源及影片标识")
        }
        for field in ["position", "duration", "index", "updated"] where dict[field] != nil {
            guard let num = dict[field] as? NSNumber, num.doubleValue >= 0 else {
                throw MarcoError.invalidFormat("备份记录的 \(field) 无效")
            }
        }
    }
}

public struct WebDavConfig: Codable, Hashable, Sendable {
    public var url: String
    public var username: String
    public var password: String
    public var autoSync: Bool
    public var syncSubscriptions: Bool
    public var syncHistory: Bool
    public var lastSyncTimeMs: Int64
    public var lastSyncStatus: String

    public init(
        url: String = "",
        username: String = "",
        password: String = "",
        autoSync: Bool = true,
        syncSubscriptions: Bool = true,
        syncHistory: Bool = true,
        lastSyncTimeMs: Int64 = 0,
        lastSyncStatus: String = ""
    ) {
        self.url = url
        self.username = username
        self.password = password
        self.autoSync = autoSync
        self.syncSubscriptions = syncSubscriptions
        self.syncHistory = syncHistory
        self.lastSyncTimeMs = lastSyncTimeMs
        self.lastSyncStatus = lastSyncStatus
    }

    public var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Dual-layer tvOS-compliant self-healing persistence manager:
/// 1) **Keychain Anchor**: persists WebDAV credentials, privacy PIN hash, subscription source URLs,
///    and a DEFLATE-compressed snapshot of favorites (up to 120) + watch history (up to 60) + preferences.
/// 2) **Caches Working Store** (`Library/Caches/MarcoMovie/`): stores full working JSON files without
///    ever touching `Documents` or exceeding `UserDefaults` limits. Automatically reconstructs state
///    from the Keychain Anchor if tvOS evicts `Caches` under disk pressure!
public final class TvStorageManager: @unchecked Sendable {
    private struct KeychainSubscriptionStub: Codable {
        var id: String
        var name: String
        var url: String
        var group: String
        var format: String
        var enabled: Bool
        var updatedAt: Int64
        var warehouseUrl: String
        var activeDepotName: String
        var depots: [CmsDepot]
    }

    private struct KeychainAnchorSnapshot: Codable {
        var version: Int = 1
        var subscriptions: [KeychainSubscriptionStub]
        var favorites: [FavoriteItem]
        var watchHistory: [WatchHistoryItem]
        var preferences: PlaybackPreferences
        var tombstones: [String: Int64]
    }

    private static let accountAnchorSnapshot = "anchor_snapshot_zlib_v1"
    private static let accountWebDavSecret = "webdav_credentials_v1"
    private static let accountPrivacyPinHash = "privacy_pin_sha256_v1"

    public static let maxSyncTombstones = 300

    private let lock = NSRecursiveLock()
    public let cachesDirectory: URL
    public let keychain: KeychainStoreProtocol

    private var subscriptionsCache: [SubscriptionEntry] = []
    private var favoritesCache: [FavoriteItem] = []
    private var historyCache: [WatchHistoryItem] = []
    private var searchHistoryCache: [String] = []
    private var preferencesCache = PlaybackPreferences()
    private var tombstonesCache: [String: Int64] = [:]
    private(set) public var recoveredFromKeychainAnchor = false
    private(set) public var needsSubscriptionContentRefresh = false

    public init(
        cachesDirectory: URL? = nil,
        keychain: KeychainStoreProtocol = SystemKeychainStore()
    ) {
        if let customDir = cachesDirectory {
            self.cachesDirectory = customDir
        } else {
            let sysCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cachesDirectory = sysCaches.appendingPathComponent("MarcoMovie", isDirectory: true)
        }
        self.keychain = keychain
        loadOrRecover()
    }

    // MARK: - Self-Healing Boot & Recovery

    public func loadOrRecover() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)

        let subsFile = cachesDirectory.appendingPathComponent("subscriptions.json")
        let favsFile = cachesDirectory.appendingPathComponent("favorites.json")
        let histFile = cachesDirectory.appendingPathComponent("history.json")
        let prefsFile = cachesDirectory.appendingPathComponent("preferences.json")
        let tombsFile = cachesDirectory.appendingPathComponent("tombstones.json")
        let searchFile = cachesDirectory.appendingPathComponent("search_history.json")

        let cachesPresent = FileManager.default.fileExists(atPath: subsFile.path)
            || FileManager.default.fileExists(atPath: favsFile.path)
            || FileManager.default.fileExists(atPath: histFile.path)
            || FileManager.default.fileExists(atPath: prefsFile.path)

        if cachesPresent {
            subscriptionsCache = readCodable(from: subsFile) ?? []
            favoritesCache = readCodable(from: favsFile) ?? []
            historyCache = readCodable(from: histFile) ?? []
            preferencesCache = readCodable(from: prefsFile) ?? PlaybackPreferences()
            tombstonesCache = readCodable(from: tombsFile) ?? [:]
            searchHistoryCache = readCodable(from: searchFile) ?? []
            recoveredFromKeychainAnchor = false
            needsSubscriptionContentRefresh = subscriptionsCache.contains { !$0.url.isEmpty && $0.rawContent.isEmpty }
        } else if let anchor = readKeychainAnchor() {
            // Caches directory was purged by tvOS! Reconstruct working state from Keychain Anchor.
            favoritesCache = Array(anchor.favorites.prefix(CmsParser.maxFavoriteEntries))
            historyCache = Array(anchor.watchHistory.prefix(CmsParser.maxHistoryEntries))
            preferencesCache = anchor.preferences
            tombstonesCache = anchor.tombstones
            subscriptionsCache = anchor.subscriptions.map { stub in
                SubscriptionEntry(
                    id: stub.id,
                    name: stub.name,
                    url: stub.url,
                    group: stub.group,
                    format: stub.format,
                    enabled: stub.enabled,
                    rawContent: "",
                    updatedAt: stub.updatedAt,
                    warehouseUrl: stub.warehouseUrl,
                    activeDepotName: stub.activeDepotName,
                    depots: stub.depots
                )
            }
            recoveredFromKeychainAnchor = true
            needsSubscriptionContentRefresh = subscriptionsCache.contains { !$0.url.isEmpty }
            persistCachesFilesOnly()
        } else {
            subscriptionsCache = []
            favoritesCache = []
            historyCache = []
            preferencesCache = PlaybackPreferences()
            tombstonesCache = [:]
            searchHistoryCache = []
            recoveredFromKeychainAnchor = false
            needsSubscriptionContentRefresh = false
        }
    }

    // MARK: - Accessors & Mutations

    public func subscriptions() -> [SubscriptionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptionsCache
    }

    public func saveSubscriptions(_ entries: [SubscriptionEntry]) {
        lock.lock()
        defer { lock.unlock() }
        subscriptionsCache = entries
        needsSubscriptionContentRefresh = entries.contains { !$0.url.isEmpty && $0.rawContent.isEmpty }
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        persistKeychainAnchor()
    }

    @discardableResult
    public func upsertSubscription(
        name: String,
        url: String,
        rawContent: String,
        warehouseUrl: String = "",
        activeDepotName: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (entry: SubscriptionEntry, config: CmsConfig) {
        let parsed = try CmsParser.parseConfig(rawContent, origin: url, defaultName: name)
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        defer { lock.unlock() }

        let existingIdx = subscriptionsCache.firstIndex { sub in
            (!cleanUrl.isEmpty && sub.url == cleanUrl)
                || (!warehouseUrl.isEmpty && sub.warehouseUrl == warehouseUrl)
        }
        let subId = existingIdx.map { subscriptionsCache[$0].id }
            ?? "sub_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"
        let displayName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if !activeDepotName.isEmpty { return activeDepotName }
            if let host = URL(string: cleanUrl)?.host, !host.isEmpty { return host }
            return "Apple TV 订阅源"
        }()

        let entry = SubscriptionEntry(
            id: subId,
            name: displayName,
            url: cleanUrl,
            format: parsed.depots.isEmpty ? "JSON" : "多仓",
            enabled: true,
            rawContent: rawContent,
            siteCount: parsed.sites.count,
            liveCount: parsed.lives.count,
            updatedAt: nowMs,
            warehouseUrl: warehouseUrl,
            activeDepotName: activeDepotName,
            depots: parsed.depots.isEmpty
                ? (existingIdx.map { subscriptionsCache[$0].depots } ?? [])
                : parsed.depots
        )

        if let idx = existingIdx {
            subscriptionsCache[idx] = entry
        } else {
            subscriptionsCache.insert(entry, at: 0)
        }

        if preferencesCache.selectedSiteKey.isEmpty,
           let firstAvail = parsed.publicAvailableSites.first(where: { !$0.isBannerNoticeSite })
               ?? parsed.publicAvailableSites.first
        {
            preferencesCache.selectedSiteKey = firstAvail.key
            writeCodableAtomically(preferencesCache, to: cachesDirectory.appendingPathComponent("preferences.json"))
        }

        let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
            url: entry.url,
            rawContent: entry.rawContent,
            warehouseUrl: entry.warehouseUrl
        )
        tombstonesCache.removeValue(forKey: "sub:\(syncKey)")
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        needsSubscriptionContentRefresh = subscriptionsCache.contains { !$0.url.isEmpty && $0.rawContent.isEmpty }
        persistKeychainAnchor()
        return (entry, parsed)
    }

    public func removeSubscription(id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        if let target = subscriptionsCache.first(where: { $0.id == id }), !target.rawContent.isEmpty {
            let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
                url: target.url,
                rawContent: target.rawContent,
                warehouseUrl: target.warehouseUrl
            )
            recordTombstoneLocked(key: "sub:\(syncKey)", timestampMs: nowMs)
        }
        subscriptionsCache.removeAll { $0.id == id }
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        persistKeychainAnchor()
    }

    /// Merges all enabled subscriptions into an aggregated `CmsConfig`.
    public func mergedConfig() -> CmsConfig {
        lock.lock()
        let activeSubs = subscriptionsCache.filter { $0.enabled && !$0.rawContent.isEmpty }
        lock.unlock()

        var allSites: [CmsSite] = []
        var allLives: [LiveSource] = []
        var allDepots: [CmsDepot] = []
        var allParses: [CmsParse] = []
        var primarySpider = ""
        var seenSiteKeys = Set<String>()
        var seenDepotUrls = Set<String>()

        for sub in activeSubs {
            for d in sub.depots where seenDepotUrls.insert(d.url).inserted {
                allDepots.append(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id))
            }
            guard let cfg = try? CmsParser.parseConfig(
                sub.rawContent,
                origin: sub.url,
                defaultGroup: sub.group,
                isPrivate: sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
                defaultName: sub.name
            ) else {
                continue
            }
            if primarySpider.isEmpty && !cfg.spider.isEmpty {
                primarySpider = cfg.spider
            }
            for d in cfg.depots where seenDepotUrls.insert(d.url).inserted {
                allDepots.append(d)
            }
            for p in cfg.parses where !allParses.contains(where: { $0.url == p.url }) {
                allParses.append(p)
            }
            for var site in cfg.sites {
                if !seenSiteKeys.insert(site.key).inserted {
                    site.key = "\(site.key)_\(sub.id)"
                    seenSiteKeys.insert(site.key)
                }
                allSites.append(site)
            }
            allLives.append(contentsOf: cfg.lives)
        }

        return CmsConfig(
            sites: allSites,
            lives: allLives,
            depots: allDepots,
            parses: allParses,
            spider: primarySpider
        )
    }

    // MARK: - Watch History & Favorites

    public func watchHistory() -> [WatchHistoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return historyCache
    }

    public func upsertWatchHistory(_ item: WatchHistoryItem) {
        lock.lock()
        defer { lock.unlock() }
        historyCache = CmsParser.upsertHistory(historyCache, entry: item)
        tombstonesCache.removeValue(forKey: "hist:\(item.key)")
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    public func removeWatchHistory(site: String, id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        historyCache.removeAll { $0.key == targetKey }
        recordTombstoneLocked(key: "hist:\(targetKey)", timestampMs: nowMs)
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        persistKeychainAnchor()
    }

    public func clearWatchHistory(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for item in historyCache {
            tombstonesCache["hist:\(item.key)"] = nowMs
        }
        boundTombstonesLocked()
        historyCache = []
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    public func favorites() -> [FavoriteItem] {
        lock.lock()
        defer { lock.unlock() }
        return favoritesCache
    }

    public func isFavorite(site: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        return favoritesCache.contains { $0.key == targetKey }
    }

    @discardableResult
    public func toggleFavorite(
        site: String,
        video: CmsVideo,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(video.id)"
        let nowFav: Bool
        if let idx = favoritesCache.firstIndex(where: { $0.key == targetKey }) {
            favoritesCache.remove(at: idx)
            tombstonesCache["fav:\(targetKey)"] = nowMs
            tombstonesCache.removeValue(forKey: "add:\(targetKey)")
            nowFav = false
        } else {
            let fav = FavoriteItem(
                site: site,
                id: video.id,
                title: video.title,
                poster: video.poster,
                remarks: video.remarks,
                updated: nowMs
            )
            favoritesCache.insert(fav, at: 0)
            if favoritesCache.count > CmsParser.maxFavoriteEntries {
                favoritesCache = Array(favoritesCache.prefix(CmsParser.maxFavoriteEntries))
            }
            tombstonesCache["add:\(targetKey)"] = nowMs
            tombstonesCache.removeValue(forKey: "fav:\(targetKey)")
            nowFav = true
        }
        boundTombstonesLocked()
        writeCodableAtomically(favoritesCache, to: cachesDirectory.appendingPathComponent("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
        return nowFav
    }

    public func removeFavorite(site: String, id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        favoritesCache.removeAll { $0.key == targetKey }
        tombstonesCache["fav:\(targetKey)"] = nowMs
        tombstonesCache.removeValue(forKey: "add:\(targetKey)")
        boundTombstonesLocked()
        writeCodableAtomically(favoritesCache, to: cachesDirectory.appendingPathComponent("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    public func clearFavorites(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for fav in favoritesCache {
            tombstonesCache["fav:\(fav.key)"] = nowMs
            tombstonesCache.removeValue(forKey: "add:\(fav.key)")
        }
        boundTombstonesLocked()
        favoritesCache = []
        writeCodableAtomically(favoritesCache, to: cachesDirectory.appendingPathComponent("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    // MARK: - Search History & Preferences

    public func searchHistory() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return searchHistoryCache
    }

    public func addSearchKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        searchHistoryCache.removeAll { $0 == trimmed }
        searchHistoryCache.insert(trimmed, at: 0)
        if searchHistoryCache.count > 16 {
            searchHistoryCache = Array(searchHistoryCache.prefix(16))
        }
        writeCodableAtomically(searchHistoryCache, to: cachesDirectory.appendingPathComponent("search_history.json"))
    }

    public func clearSearchHistory() {
        lock.lock()
        defer { lock.unlock() }
        searchHistoryCache = []
        writeCodableAtomically(searchHistoryCache, to: cachesDirectory.appendingPathComponent("search_history.json"))
    }

    public func preferences() -> PlaybackPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferencesCache
    }

    public func updatePreferences(_ transform: (inout PlaybackPreferences) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var next = preferencesCache
        transform(&next)
        preferencesCache = PlaybackPreferences(
            skipIntroSec: next.skipIntroSec,
            skipOutroSec: next.skipOutroSec,
            playSpeed: next.playSpeed,
            autoNext: next.autoNext,
            episodesDescending: next.episodesDescending,
            repeatMode: next.repeatMode,
            selectedSiteKey: next.selectedSiteKey,
            preferredSiteKey: next.preferredSiteKey
        )
        writeCodableAtomically(preferencesCache, to: cachesDirectory.appendingPathComponent("preferences.json"))
        persistKeychainAnchor()
    }

    public func tombstones() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return tombstonesCache
    }

    internal func applyMergedSyncState(
        subscriptions: [SubscriptionEntry],
        watchHistory: [WatchHistoryItem],
        favorites: [FavoriteItem],
        tombstones: [String: Int64]
    ) {
        lock.lock()
        defer { lock.unlock() }
        subscriptionsCache = subscriptions
        historyCache = Array(watchHistory.prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array(favorites.prefix(CmsParser.maxFavoriteEntries))
        tombstonesCache = tombstones
        boundTombstonesLocked()
        persistCachesFilesOnly()
        persistKeychainAnchor()
    }

    // MARK: - Keychain Credentials (WebDAV & Privacy PIN)

    public func loadWebDavConfig() -> WebDavConfig {
        guard let data = try? keychain.data(forAccount: Self.accountWebDavSecret),
              let cfg = try? JSONDecoder().decode(WebDavConfig.self, from: data)
        else {
            return WebDavConfig()
        }
        return cfg
    }

    public func saveWebDavConfig(_ config: WebDavConfig) throws {
        let encoded = try JSONEncoder().encode(config)
        try keychain.setData(encoded, forAccount: Self.accountWebDavSecret)
    }

    public func setPrivacyPin(_ pin: String) throws {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.removeData(forAccount: Self.accountPrivacyPinHash)
            return
        }
        let hashHex = SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
        try keychain.setData(Data(hashHex.utf8), forAccount: Self.accountPrivacyPinHash)
    }

    public func verifyPrivacyPin(_ pin: String) -> Bool {
        guard let storedData = try? keychain.data(forAccount: Self.accountPrivacyPinHash),
              let storedHex = String(data: storedData, encoding: .utf8),
              !storedHex.isEmpty
        else {
            return true
        }
        let candidateHex = SHA256.hash(data: Data(pin.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return candidateHex == storedHex
    }

    // MARK: - Backup Export, Import & Reset

    public func exportBackupJson(exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> String {
        lock.lock()
        let pubSubs = subscriptionsCache.filter { !$0.isEffectivelyPrivate }
        let payload = BackupPayload(
            exportedAt: exportedAt,
            origin: pubSubs.first?.url ?? "",
            rawConfig: pubSubs.first?.rawContent ?? "",
            subscriptions: pubSubs,
            watchHistory: historyCache,
            favorites: favoritesCache,
            searchHistory: searchHistoryCache,
            preferences: preferencesCache
        )
        lock.unlock()
        return try BackupCodec.encodeBackupJson(payload)
    }

    @discardableResult
    public func importBackupJson(_ rawBackup: String) throws -> CmsConfig {
        let decoded = try BackupCodec.decodeBackupJson(rawBackup)
        lock.lock()
        let retainedPrivateSubs = subscriptionsCache.filter { $0.isEffectivelyPrivate }
        subscriptionsCache = decoded.subscriptions + retainedPrivateSubs
        historyCache = Array(decoded.watchHistory.prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array(decoded.favorites.prefix(CmsParser.maxFavoriteEntries))
        searchHistoryCache = Array(decoded.searchHistory.prefix(16))
        preferencesCache = decoded.preferences
        needsSubscriptionContentRefresh = false
        persistCachesFilesOnly()
        persistKeychainAnchor()
        lock.unlock()
        return mergedConfig()
    }

    public func resetAllData() throws {
        lock.lock()
        defer { lock.unlock() }
        subscriptionsCache = []
        favoritesCache = []
        historyCache = []
        searchHistoryCache = []
        preferencesCache = PlaybackPreferences()
        tombstonesCache = [:]
        recoveredFromKeychainAnchor = false
        needsSubscriptionContentRefresh = false
        try? FileManager.default.removeItem(at: cachesDirectory)
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        try? keychain.removeData(forAccount: Self.accountAnchorSnapshot)
        try? keychain.removeData(forAccount: Self.accountWebDavSecret)
        try? keychain.removeData(forAccount: Self.accountPrivacyPinHash)
    }

    // MARK: - Internal File & Keychain Anchor I/O

    private func persistCachesFilesOnly() {
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        writeCodableAtomically(favoritesCache, to: cachesDirectory.appendingPathComponent("favorites.json"))
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        writeCodableAtomically(preferencesCache, to: cachesDirectory.appendingPathComponent("preferences.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        writeCodableAtomically(searchHistoryCache, to: cachesDirectory.appendingPathComponent("search_history.json"))
    }

    private func persistKeychainAnchor() {
        let stubs = subscriptionsCache.map { sub in
            KeychainSubscriptionStub(
                id: sub.id,
                name: sub.name,
                url: sub.url,
                group: sub.group,
                format: sub.format,
                enabled: sub.enabled,
                updatedAt: sub.updatedAt,
                warehouseUrl: sub.warehouseUrl,
                activeDepotName: sub.activeDepotName,
                depots: sub.depots
            )
        }
        let snapshot = KeychainAnchorSnapshot(
            subscriptions: stubs,
            favorites: Array(favoritesCache.prefix(CmsParser.maxFavoriteEntries)),
            watchHistory: Array(historyCache.prefix(CmsParser.maxHistoryEntries)),
            preferences: preferencesCache,
            tombstones: tombstonesCache
        )
        guard let rawJson = try? JSONEncoder().encode(snapshot),
              let compressed = ConfigDecoder.compressDeflate(rawJson)
        else {
            return
        }
        try? keychain.setData(compressed, forAccount: Self.accountAnchorSnapshot)
    }

    private func readKeychainAnchor() -> KeychainAnchorSnapshot? {
        guard let compressed = try? keychain.data(forAccount: Self.accountAnchorSnapshot),
              let rawJson = ConfigDecoder.decompressDeflate(compressed),
              let snapshot = try? JSONDecoder().decode(KeychainAnchorSnapshot.self, from: rawJson)
        else {
            return nil
        }
        return snapshot
    }

    private func recordTombstoneLocked(key: String, timestampMs: Int64) {
        guard !key.isEmpty, timestampMs > 0 else { return }
        tombstonesCache[key] = timestampMs
        boundTombstonesLocked()
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
    }

    private func boundTombstonesLocked() {
        guard tombstonesCache.count > Self.maxSyncTombstones else { return }
        let sorted = tombstonesCache.sorted { $0.value > $1.value }.prefix(Self.maxSyncTombstones)
        tombstonesCache = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
    }

    private func readCodable<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeCodableAtomically<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

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
    public static let keyNetdiskQuality = "netdisk_quality"
    public static let keyPlayerKernel = "player_kernel"
    public static let keyAmbientTheme = "ambient_theme"
    public static let keyAmbientIntensity = "ambient_intensity"
    public static let keyAmbientPosterSync = "ambient_poster_sync"

    public static func encodeBackupJson(_ payload: BackupPayload) throws -> String {
        let publicSubs = payload.subscriptions.compactMap { $0.sanitizedForPublicExport() }
        let privateSubs = payload.subscriptions.filter { $0.isEffectivelyPrivate }
        let privateConfig = TvStorageManager.buildOwnershipConfig(
            from: payload.subscriptions,
            knownPrivateSubscriptionIds: Set(privateSubs.map(\.id)),
            knownPrivateSiteKeys: [],
            ambiguousLegacyRawKeys: []
        )
        let safeWatchHistory = payload.watchHistory.filter { !privateConfig.isPrivateSiteKey($0.site) }
        let safeFavorites = payload.favorites.filter { !privateConfig.isPrivateSiteKey($0.site) }
        let safeSelectedSite = privateConfig.isPrivateSiteKey(payload.preferences.selectedSiteKey)
            ? ""
            : payload.preferences.selectedSiteKey
        let safePreferredSite = privateConfig.isPrivateSiteKey(payload.preferences.preferredSiteKey)
            ? ""
            : payload.preferences.preferredSiteKey

        let primaryOrigin = !payload.origin.isEmpty ? payload.origin : (publicSubs.first?.url ?? "")
        let rawPrimary = !payload.rawConfig.isEmpty ? payload.rawConfig : (publicSubs.first?.rawContent ?? "")
        let primaryRawConfig = CmsParser.sanitizePublicRawConfig(rawPrimary)

        let configField: Any = {
            let trimmed = primaryRawConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return NSNull() }
            let cleaned = ConfigDecoder.stripJsonComments(ConfigDecoder.unpackConfigText(trimmed))
            if let jsonObj = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) {
                return jsonObj
            }
            return trimmed
        }()

        let histJson = try stringifyJsonArray(safeWatchHistory.map { $0.toDictionary() })
        let favJson = try stringifyJsonArray(safeFavorites.map { $0.toDictionary() })
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
            keySelectedSite: safeSelectedSite,
            keyPreferredSite: safePreferredSite,
            keyNetdiskQuality: payload.preferences.netdiskQuality,
            keyPlayerKernel: payload.preferences.playerKernel,
            keyAmbientTheme: payload.preferences.ambientTheme,
            keyAmbientIntensity: payload.preferences.ambientIntensity,
            keyAmbientPosterSync: payload.preferences.ambientPosterSync,
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
            preferredSiteKey: (settings[keyPreferredSite] as? String) ?? "",
            netdiskQuality: (settings[keyNetdiskQuality] as? String) ?? "auto",
            playerKernel: (settings[keyPlayerKernel] as? String) ?? "range_proxy",
            ambientTheme: (settings[keyAmbientTheme] as? String) ?? "aurora",
            ambientIntensity: (settings[keyAmbientIntensity] as? String) ?? "standard",
            ambientPosterSync: (settings[keyAmbientPosterSync] as? Bool) ?? true
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
        var isPrivate: Bool?
        var enabled: Bool
        var updatedAt: Int64
        var warehouseUrl: String
        var activeDepotName: String
        var depots: [CmsDepot]
    }

    private struct PrivacyAndIdentityMetadata: Codable {
        var knownPrivateSubscriptionIds: [String] = []
        var knownPrivateSiteKeys: [String] = []
        var ambiguousLegacyRawKeys: [String] = []
        var transitionedToPrivateSubIds: [String]?
        var transitionedToPrivateSiteKeys: [String]?
    }

    private struct KeychainAnchorSnapshot: Codable {
        var version: Int = 3
        var subscriptions: [KeychainSubscriptionStub]
        var favorites: [FavoriteItem]
        var watchHistory: [WatchHistoryItem]
        var preferences: PlaybackPreferences
        var tombstones: [String: Int64]
        var knownPrivateSubscriptionIds: [String]?
        var knownPrivateSiteKeys: [String]?
        var ambiguousLegacyRawKeys: [String]?
        var transitionedToPrivateSubIds: [String]?
        var transitionedToPrivateSiteKeys: [String]?
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
    private var knownPrivateSubscriptionIdsCache: Set<String> = []
    private var knownPrivateSiteKeysCache: Set<String> = []
    private var ambiguousLegacyRawKeysCache: Set<String> = []
    private var transitionedToPrivateSubIdsCache: Set<String> = []
    private var transitionedToPrivateSiteKeysCache: Set<String> = []
    private var mutationVersionCounter: UInt64 = 0
    private(set) public var recoveredFromKeychainAnchor = false
    private(set) public var needsSubscriptionContentRefresh = false

    internal struct SyncStorageSnapshot: Sendable {
        let subscriptions: [SubscriptionEntry]
        let watchHistory: [WatchHistoryItem]
        let favorites: [FavoriteItem]
        let tombstones: [String: Int64]
        let knownPrivateSubscriptionIds: Set<String>
        let knownPrivateSiteKeys: Set<String>
        let ambiguousLegacyRawKeys: Set<String>
        let transitionedToPrivateSubIds: Set<String>
        let transitionedToPrivateSiteKeys: Set<String>
        let version: UInt64
    }

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
        let metaFile = cachesDirectory.appendingPathComponent("privacy_meta.json")

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
            if let meta: PrivacyAndIdentityMetadata = readCodable(from: metaFile) {
                knownPrivateSubscriptionIdsCache = Set(meta.knownPrivateSubscriptionIds)
                knownPrivateSiteKeysCache = Set(meta.knownPrivateSiteKeys)
                ambiguousLegacyRawKeysCache = Set(meta.ambiguousLegacyRawKeys)
                transitionedToPrivateSubIdsCache = Set(meta.transitionedToPrivateSubIds ?? [])
                transitionedToPrivateSiteKeysCache = Set(meta.transitionedToPrivateSiteKeys ?? [])
            } else {
                knownPrivateSubscriptionIdsCache = []
                knownPrivateSiteKeysCache = []
                ambiguousLegacyRawKeysCache = []
                transitionedToPrivateSubIdsCache = []
                transitionedToPrivateSiteKeysCache = []
            }
            syncMetadataTrackersLocked()
            recoveredFromKeychainAnchor = false
            needsSubscriptionContentRefresh = subscriptionsCache.contains {
                $0.enabled && !$0.isEffectivelyPrivate && !$0.url.isEmpty && $0.rawContent.isEmpty
            }
        } else if let anchor = readKeychainAnchor() {
            // Caches directory was purged by tvOS! Reconstruct working state from Keychain Anchor.
            favoritesCache = Array(anchor.favorites.prefix(CmsParser.maxFavoriteEntries))
            historyCache = Array(anchor.watchHistory.prefix(CmsParser.maxHistoryEntries))
            preferencesCache = anchor.preferences
            tombstonesCache = anchor.tombstones
            knownPrivateSubscriptionIdsCache = Set(anchor.knownPrivateSubscriptionIds ?? [])
            knownPrivateSiteKeysCache = Set(anchor.knownPrivateSiteKeys ?? [])
            ambiguousLegacyRawKeysCache = Set(anchor.ambiguousLegacyRawKeys ?? [])
            transitionedToPrivateSubIdsCache = Set(anchor.transitionedToPrivateSubIds ?? [])
            transitionedToPrivateSiteKeysCache = Set(anchor.transitionedToPrivateSiteKeys ?? [])
            subscriptionsCache = anchor.subscriptions.map { stub in
                // Legacy v1 Keychain stubs omitted `isPrivate`; when privacy cannot be determined,
                // conservatively treat the recovered subscription as private to avoid exposing hidden sources.
                let inferredPrivate = stub.isPrivate ?? true
                let effectivePrivate = inferredPrivate || stub.group.contains("隐私") || stub.group.contains("私密")
                let restoredDepots = stub.depots.map { d in
                    CmsDepot(
                        name: d.name,
                        url: d.url,
                        subscriptionId: d.subscriptionId.isEmpty ? stub.id : d.subscriptionId,
                        isPrivate: effectivePrivate || d.isPrivate
                    )
                }
                return SubscriptionEntry(
                    id: stub.id,
                    name: stub.name,
                    url: stub.url,
                    group: stub.group,
                    format: stub.format,
                    isPrivate: effectivePrivate,
                    enabled: stub.enabled,
                    rawContent: "",
                    updatedAt: stub.updatedAt,
                    warehouseUrl: stub.warehouseUrl,
                    activeDepotName: stub.activeDepotName,
                    depots: restoredDepots
                )
            }
            syncMetadataTrackersLocked()
            recoveredFromKeychainAnchor = true
            needsSubscriptionContentRefresh = subscriptionsCache.contains {
                $0.enabled && !$0.isEffectivelyPrivate && !$0.url.isEmpty
            }
            persistCachesFilesOnly()
        } else {
            subscriptionsCache = []
            favoritesCache = []
            historyCache = []
            preferencesCache = PlaybackPreferences()
            tombstonesCache = [:]
            searchHistoryCache = []
            knownPrivateSubscriptionIdsCache = []
            knownPrivateSiteKeysCache = []
            ambiguousLegacyRawKeysCache = []
            transitionedToPrivateSubIdsCache = []
            transitionedToPrivateSiteKeysCache = []
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
        let previousSubs = subscriptionsCache
        // Preserve historical ambiguity & deleted private identities before overwriting subscriptions.
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        for nextSub in entries where !nextSub.id.isEmpty && nextSub.isEffectivelyPrivate {
            if let prev = previousSubs.first(where: { $0.id == nextSub.id }), !prev.isEffectivelyPrivate {
                transitionedToPrivateSubIdsCache.insert(nextSub.id)
            }
        }
        subscriptionsCache = entries
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        mutationVersionCounter &+= 1
        recomputeNeedsRefreshLocked()
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        persistPrivacyMetaLocked()
        persistKeychainAnchor()
    }

    @discardableResult
    public func upsertSubscription(
        id existingTargetId: String? = nil,
        name: String,
        url: String,
        rawContent: String,
        group: String? = nil,
        isPrivate: Bool? = nil,
        enabled: Bool? = nil,
        warehouseUrl: String = "",
        activeDepotName: String = "",
        depots: [CmsDepot]? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (entry: SubscriptionEntry, config: CmsConfig) {
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWarehouse = warehouseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDepotName = activeDepotName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTargetId = existingTargetId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Snapshot existing subscription metadata first so refresh & depot switch preserve
        // original id, group, privacy, enabled state, and owning warehouse.
        lock.lock()
        let existingSnapshot: SubscriptionEntry? = {
            if !cleanTargetId.isEmpty,
               let byId = subscriptionsCache.first(where: { $0.id == cleanTargetId })
            {
                return byId
            }
            if !cleanWarehouse.isEmpty,
               let byWarehouse = subscriptionsCache.first(where: { $0.warehouseUrl == cleanWarehouse || $0.url == cleanWarehouse })
            {
                return byWarehouse
            }
            if !cleanUrl.isEmpty,
               let byUrl = subscriptionsCache.first(where: { $0.url == cleanUrl })
            {
                return byUrl
            }
            return nil
        }()
        let existingIdsSnapshot = Set(subscriptionsCache.map(\.id))
        lock.unlock()

        let effectiveWarehouseForId = !cleanWarehouse.isEmpty ? cleanWarehouse : (existingSnapshot?.warehouseUrl ?? "")
        let subId: String = {
            if let prevId = existingSnapshot?.id, !prevId.isEmpty {
                return prevId
            }
            if !cleanTargetId.isEmpty {
                return cleanTargetId
            }
            // Deterministic cross-device subscription ID derived from canonical URL/warehouse/content
            // so two Apple TVs importing the same URL produce identical canonical site keys.
            if let deterministic = WebDavSyncService.canonicalWireSubscriptionId(
                url: cleanUrl,
                rawContent: rawContent,
                warehouseUrl: effectiveWarehouseForId
            ), !existingIdsSnapshot.contains(deterministic) {
                return deterministic
            }
            return "sub_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())"
        }()
        let effectiveGroup: String = {
            if let explicit = group?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                return explicit
            }
            if let prev = existingSnapshot?.group.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
                return prev
            }
            return "默认分组"
        }()
        let effectivePrivate = (isPrivate ?? existingSnapshot?.isEffectivelyPrivate ?? false)
            || effectiveGroup.contains("隐私")
            || effectiveGroup.contains("私密")
        let effectiveEnabled = enabled ?? existingSnapshot?.enabled ?? true
        let effectiveWarehouse = !cleanWarehouse.isEmpty ? cleanWarehouse : (existingSnapshot?.warehouseUrl ?? "")
        let effectiveActiveDepot = !cleanDepotName.isEmpty ? cleanDepotName : (existingSnapshot?.activeDepotName ?? "")

        let displayName: String = {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if let prevName = existingSnapshot?.name.trimmingCharacters(in: .whitespacesAndNewlines), !prevName.isEmpty {
                return prevName
            }
            if !effectiveActiveDepot.isEmpty { return effectiveActiveDepot }
            if let host = URL(string: cleanUrl)?.host, !host.isEmpty { return host }
            return "Apple TV 订阅源"
        }()

        let parsed = try CmsParser.parseConfig(
            rawContent,
            origin: cleanUrl,
            defaultGroup: effectiveGroup,
            isPrivate: effectivePrivate,
            subscriptionId: subId,
            defaultName: displayName
        )

        lock.lock()
        defer { lock.unlock() }

        let existingIdx: Int? = {
            if !cleanTargetId.isEmpty,
               let idx = subscriptionsCache.firstIndex(where: { $0.id == cleanTargetId })
            {
                return idx
            }
            if let snap = existingSnapshot,
               let idx = subscriptionsCache.firstIndex(where: { $0.id == snap.id })
            {
                return idx
            }
            if !cleanWarehouse.isEmpty,
               let idx = subscriptionsCache.firstIndex(where: { $0.warehouseUrl == cleanWarehouse || $0.url == cleanWarehouse })
            {
                return idx
            }
            if !cleanUrl.isEmpty,
               let idx = subscriptionsCache.firstIndex(where: { $0.url == cleanUrl })
            {
                return idx
            }
            return nil
        }()

        let rawDepots: [CmsDepot] = {
            if let explicitDepots = depots, !explicitDepots.isEmpty {
                return explicitDepots
            }
            if !parsed.depots.isEmpty {
                return parsed.depots
            }
            if let idx = existingIdx {
                return subscriptionsCache[idx].depots
            }
            return []
        }()
        let normalizedDepots = rawDepots.map { d in
            CmsDepot(
                name: d.name,
                url: d.url,
                subscriptionId: subId,
                isPrivate: effectivePrivate || d.isPrivate
            )
        }

        let effectiveFormat: String = {
            if !normalizedDepots.isEmpty || !effectiveWarehouse.isEmpty {
                return "多仓"
            }
            if let idx = existingIdx, !subscriptionsCache[idx].format.isEmpty {
                return subscriptionsCache[idx].format
            }
            return "JSON"
        }()

        let entry = SubscriptionEntry(
            id: subId,
            name: displayName,
            url: cleanUrl,
            group: effectiveGroup,
            format: effectiveFormat,
            isPrivate: effectivePrivate,
            enabled: effectiveEnabled,
            rawContent: rawContent,
            siteCount: parsed.sites.count,
            liveCount: parsed.lives.count,
            updatedAt: nowMs,
            warehouseUrl: effectiveWarehouse,
            activeDepotName: effectiveActiveDepot,
            depots: normalizedDepots
        )

        let previousEntry = existingIdx.map { subscriptionsCache[$0] }
        if let prev = previousEntry, !prev.isEffectivelyPrivate && effectivePrivate && !subId.isEmpty {
            transitionedToPrivateSubIdsCache.insert(subId)
        }
        if let idx = existingIdx {
            subscriptionsCache[idx] = entry
        } else {
            subscriptionsCache.insert(entry, at: 0)
        }

        if effectiveEnabled,
           !effectivePrivate,
           preferencesCache.selectedSiteKey.isEmpty,
           let firstAvail = parsed.publicAvailableSites.first(where: { !$0.isBannerNoticeSite })
               ?? parsed.publicAvailableSites.first
        {
            preferencesCache.selectedSiteKey = CmsSite.canonicalScopedKey(
                rawKey: firstAvail.rawKey,
                subscriptionId: subId
            )
            writeCodableAtomically(preferencesCache, to: cachesDirectory.appendingPathComponent("preferences.json"))
        }

        if !effectivePrivate {
            let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
                url: entry.url,
                rawContent: entry.rawContent,
                warehouseUrl: entry.warehouseUrl
            )
            tombstonesCache.removeValue(forKey: "sub:\(syncKey)")
            writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        }
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        syncMetadataTrackersLocked(additionalSubs: previousEntry.map { [$0] } ?? [])
        persistPrivacyMetaLocked()
        mutationVersionCounter &+= 1
        recomputeNeedsRefreshLocked()
        persistKeychainAnchor()
        return (entry, parsed)
    }

    public func removeSubscription(id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let removedTarget = subscriptionsCache.first(where: { $0.id == id })
        // Record historical raw-key ambiguity AND private identity BEFORE deleting the subscription!
        syncMetadataTrackersLocked(additionalSubs: removedTarget.map { [$0] } ?? [])
        if let target = removedTarget,
           (!target.rawContent.isEmpty || !target.url.isEmpty || !target.warehouseUrl.isEmpty)
        {
            if !target.isEffectivelyPrivate {
                let syncKey = WebDavSyncService.canonicalSubscriptionSyncKey(
                    url: target.url,
                    rawContent: target.rawContent,
                    warehouseUrl: target.warehouseUrl
                )
                let effectiveDeleteTs = max(nowMs, target.updatedAt + 1)
                recordTombstoneLocked(key: "sub:\(syncKey)", timestampMs: effectiveDeleteTs)
            }
        }
        subscriptionsCache.removeAll { $0.id == id }
        syncMetadataTrackersLocked(additionalSubs: removedTarget.map { [$0] } ?? [])
        mutationVersionCounter &+= 1
        recomputeNeedsRefreshLocked()
        writeCodableAtomically(subscriptionsCache, to: cachesDirectory.appendingPathComponent("subscriptions.json"))
        persistPrivacyMetaLocked()
        persistKeychainAnchor()
    }

    internal static func buildOwnershipConfig(
        from allSubsSnapshot: [SubscriptionEntry],
        knownPrivateSubscriptionIds: Set<String>,
        knownPrivateSiteKeys: Set<String>,
        ambiguousLegacyRawKeys: Set<String>
    ) -> CmsConfig {
        var allSites: [CmsSite] = []
        var allLives: [LiveSource] = []
        var allDepots: [CmsDepot] = []
        var allParses: [CmsParse] = []
        var allOwners: [SiteOwnershipRecord] = []
        var privateSubIds = knownPrivateSubscriptionIds
        var publicSubIds = Set<String>()
        var unhydratedPublicSubIds = Set<String>()
        var primarySpider = ""
        var seenDepotUrls = Set<String>()

        for sub in allSubsSnapshot {
            let subPriv = sub.isEffectivelyPrivate
            if !sub.id.isEmpty {
                if subPriv {
                    privateSubIds.insert(sub.id)
                } else {
                    publicSubIds.insert(sub.id)
                    if sub.rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        unhydratedPublicSubIds.insert(sub.id)
                    }
                    privateSubIds.remove(sub.id)
                }
            }

            if sub.enabled && !sub.rawContent.isEmpty {
                for d in sub.depots where seenDepotUrls.insert(d.url).inserted {
                    allDepots.append(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id, isPrivate: subPriv || d.isPrivate))
                }
            }

            guard !sub.rawContent.isEmpty,
                  let cfg = try? CmsParser.parseConfig(
                      sub.rawContent,
                      origin: sub.url,
                      defaultGroup: sub.group,
                      isPrivate: subPriv,
                      subscriptionId: sub.id,
                      defaultName: sub.name
                  )
            else {
                continue
            }

            // Assign stable canonical keys scoped to this subscription's ID alone (never dependent on
            // sibling subscriptions' ordering or enabled state).
            var intraSubRawCounts: [String: Int] = [:]
            var scopedSites: [CmsSite] = []
            for var site in cfg.sites {
                let originalRawKey = site.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? site.key
                    : site.rawKey
                let occurrence = intraSubRawCounts[originalRawKey, default: 0]
                intraSubRawCounts[originalRawKey] = occurrence + 1
                let disambiguatedRaw = occurrence == 0 ? originalRawKey : "\(originalRawKey)#\(occurrence + 1)"
                let canonicalKey = CmsSite.canonicalScopedKey(rawKey: disambiguatedRaw, subscriptionId: sub.id)

                site.rawKey = originalRawKey
                site.key = canonicalKey
                site.subscriptionId = sub.id
                site.isPrivate = subPriv || site.isEffectivelyPrivate

                allOwners.append(
                    SiteOwnershipRecord(
                        canonicalKey: canonicalKey,
                        rawKey: originalRawKey,
                        subscriptionId: sub.id,
                        subscriptionName: sub.name,
                        siteName: site.name,
                        isEnabled: sub.enabled,
                        isPrivate: site.isEffectivelyPrivate,
                        isSupported: site.supported,
                        unsupportedReason: site.unsupportedReason
                    )
                )
                scopedSites.append(site)
            }

            guard sub.enabled else { continue }

            if primarySpider.isEmpty && !cfg.spider.isEmpty {
                primarySpider = cfg.spider
            }
            for d in cfg.depots where seenDepotUrls.insert(d.url).inserted {
                allDepots.append(CmsDepot(name: d.name, url: d.url, subscriptionId: sub.id, isPrivate: subPriv || d.isPrivate))
            }
            for p in cfg.parses where !allParses.contains(where: { $0.url == p.url }) {
                allParses.append(p)
            }
            allSites.append(contentsOf: scopedSites)
            for var live in cfg.lives {
                live.isPrivate = subPriv || live.isEffectivelyPrivate
                live.subscriptionId = sub.id
                if var plugin = live.plugin {
                    plugin.isPrivate = subPriv || plugin.isEffectivelyPrivate
                    plugin.subscriptionId = sub.id
                    live.plugin = plugin
                }
                allLives.append(live)
            }
        }

        return CmsConfig(
            sites: allSites,
            lives: allLives,
            depots: allDepots,
            parses: allParses,
            spider: primarySpider,
            siteOwners: allOwners,
            privateSubscriptionIds: privateSubIds,
            publicSubscriptionIds: publicSubIds,
            unhydratedPublicSubscriptionIds: unhydratedPublicSubIds,
            knownPrivateSiteKeys: knownPrivateSiteKeys,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeys
        )
    }

    /// Merges all enabled subscriptions into an aggregated `CmsConfig` while assigning every site an
    /// order-independent, disable-independent canonical key (`sub::<subscriptionId>::<rawKey>`) and
    /// capturing complete site-ownership, historical ambiguity & privacy metadata across ALL subscriptions.
    public func mergedConfig() -> CmsConfig {
        lock.lock()
        syncMetadataTrackersLocked()
        let allSubsSnapshot = subscriptionsCache
        let privSubs = knownPrivateSubscriptionIdsCache
        let privKeys = knownPrivateSiteKeysCache
        let ambigRaw = ambiguousLegacyRawKeysCache
        lock.unlock()

        return Self.buildOwnershipConfig(
            from: allSubsSnapshot,
            knownPrivateSubscriptionIds: privSubs,
            knownPrivateSiteKeys: privKeys,
            ambiguousLegacyRawKeys: ambigRaw
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
        var normalized = item
        if let prevDel = tombstonesCache["hist:\(item.key)"], normalized.updated <= prevDel {
            normalized.updated = prevDel + 1
        }
        if let prevExisting = historyCache.first(where: { $0.key == item.key }),
           normalized.updated <= prevExisting.updated
        {
            normalized.updated = prevExisting.updated + 1
        }

        // When resuming/updating an unambiguously identified legacy bare or suffixed record using
        // its canonical scoped site key, consolidate into a single card and tombstone the superseded
        // legacy key so WebDAV sync does not resurrect a duplicate card.
        if let parsed = CmsSite.parseScopedKey(normalized.site) {
            let legacySuffixed = "\(parsed.rawKey)_\(parsed.subscriptionId)"
            let bareAllowed = isUnambiguousLegacyRawKeyLocked(parsed.rawKey, forSubscriptionId: parsed.subscriptionId)
            let legacyMatches = historyCache.filter { existing in
                guard existing.id == normalized.id, existing.site != normalized.site else { return false }
                if existing.site == legacySuffixed { return true }
                if bareAllowed && existing.site == parsed.rawKey { return true }
                return false
            }
            if !legacyMatches.isEmpty {
                for old in legacyMatches {
                    if normalized.updated <= old.updated {
                        normalized.updated = old.updated + 1
                    }
                    tombstonesCache["hist:\(old.key)"] = max(normalized.updated, old.updated + 1)
                }
                let legacyKeys = Set(legacyMatches.map(\.key))
                historyCache.removeAll { legacyKeys.contains($0.key) }
                boundTombstonesLocked()
            }
        }

        historyCache = CmsParser.upsertHistory(historyCache, entry: normalized)
        tombstonesCache.removeValue(forKey: "hist:\(normalized.key)")
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    public func removeWatchHistory(site: String, id: String, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        let targetKey = "\(site)\n\(id)"
        let existingTs = historyCache.first(where: { $0.key == targetKey })?.updated ?? 0
        historyCache.removeAll { $0.key == targetKey }
        recordTombstoneLocked(key: "hist:\(targetKey)", timestampMs: max(nowMs, existingTs + 1))
        mutationVersionCounter &+= 1
        writeCodableAtomically(historyCache, to: cachesDirectory.appendingPathComponent("history.json"))
        persistKeychainAnchor()
    }

    public func clearWatchHistory(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for item in historyCache {
            tombstonesCache["hist:\(item.key)"] = max(nowMs, item.updated + 1)
        }
        boundTombstonesLocked()
        historyCache = []
        mutationVersionCounter &+= 1
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
            let removedTs = favoritesCache[idx].updated
            let prevAddTs = tombstonesCache["add:\(targetKey)"] ?? 0
            let effectiveDelTs = max(nowMs, max(removedTs, prevAddTs) + 1)
            favoritesCache.remove(at: idx)
            tombstonesCache["fav:\(targetKey)"] = effectiveDelTs
            tombstonesCache.removeValue(forKey: "add:\(targetKey)")
            nowFav = false
        } else if let parsed = CmsSite.parseScopedKey(site),
                  let legacyIdx = favoritesCache.firstIndex(where: { existing in
                      guard existing.id == video.id, existing.site != site else { return false }
                      if existing.site == "\(parsed.rawKey)_\(parsed.subscriptionId)" { return true }
                      if existing.site == parsed.rawKey {
                          return isUnambiguousLegacyRawKeyLocked(parsed.rawKey, forSubscriptionId: parsed.subscriptionId)
                      }
                      return false
                  })
        {
            let removed = favoritesCache.remove(at: legacyIdx)
            let prevAddTs = tombstonesCache["add:\(removed.key)"] ?? 0
            let effectiveDelTs = max(nowMs, max(removed.updated, prevAddTs) + 1)
            tombstonesCache["fav:\(removed.key)"] = effectiveDelTs
            tombstonesCache.removeValue(forKey: "add:\(removed.key)")
            nowFav = false
        } else {
            let prevDelTs = tombstonesCache["fav:\(targetKey)"] ?? 0
            let effectiveAddTs = max(nowMs, prevDelTs + 1)
            let fav = FavoriteItem(
                site: site,
                id: video.id,
                title: video.title,
                poster: video.poster,
                remarks: video.remarks,
                updated: effectiveAddTs
            )
            favoritesCache.insert(fav, at: 0)
            if favoritesCache.count > CmsParser.maxFavoriteEntries {
                favoritesCache = Array(favoritesCache.prefix(CmsParser.maxFavoriteEntries))
            }
            tombstonesCache["add:\(targetKey)"] = effectiveAddTs
            tombstonesCache.removeValue(forKey: "fav:\(targetKey)")
            nowFav = true
        }
        mutationVersionCounter &+= 1
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
        let removedTs = favoritesCache.first(where: { $0.key == targetKey })?.updated ?? 0
        let prevAddTs = tombstonesCache["add:\(targetKey)"] ?? 0
        let effectiveDelTs = max(nowMs, max(removedTs, prevAddTs) + 1)
        favoritesCache.removeAll { $0.key == targetKey }
        tombstonesCache["fav:\(targetKey)"] = effectiveDelTs
        tombstonesCache.removeValue(forKey: "add:\(targetKey)")
        mutationVersionCounter &+= 1
        boundTombstonesLocked()
        writeCodableAtomically(favoritesCache, to: cachesDirectory.appendingPathComponent("favorites.json"))
        writeCodableAtomically(tombstonesCache, to: cachesDirectory.appendingPathComponent("tombstones.json"))
        persistKeychainAnchor()
    }

    public func clearFavorites(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        lock.lock()
        defer { lock.unlock() }
        for fav in favoritesCache {
            let prevAdd = tombstonesCache["add:\(fav.key)"] ?? 0
            tombstonesCache["fav:\(fav.key)"] = max(nowMs, max(fav.updated, prevAdd) + 1)
            tombstonesCache.removeValue(forKey: "add:\(fav.key)")
        }
        boundTombstonesLocked()
        favoritesCache = []
        mutationVersionCounter &+= 1
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
            preferredSiteKey: next.preferredSiteKey,
            netdiskQuality: next.netdiskQuality,
            playerKernel: next.playerKernel,
            ambientTheme: next.ambientTheme,
            ambientIntensity: next.ambientIntensity,
            ambientPosterSync: next.ambientPosterSync
        )
        writeCodableAtomically(preferencesCache, to: cachesDirectory.appendingPathComponent("preferences.json"))
        persistKeychainAnchor()
    }

    public func tombstones() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return tombstonesCache
    }

    internal func captureSyncSnapshot() -> SyncStorageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        syncMetadataTrackersLocked()
        return SyncStorageSnapshot(
            subscriptions: subscriptionsCache,
            watchHistory: historyCache,
            favorites: favoritesCache,
            tombstones: tombstonesCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache,
            transitionedToPrivateSubIds: transitionedToPrivateSubIdsCache,
            transitionedToPrivateSiteKeys: transitionedToPrivateSiteKeysCache,
            version: mutationVersionCounter
        )
    }

    internal func commitSyncTransform<Result>(
        _ transform: (SyncStorageSnapshot) throws -> (
            subscriptions: [SubscriptionEntry],
            watchHistory: [WatchHistoryItem],
            favorites: [FavoriteItem],
            tombstones: [String: Int64],
            result: Result
        )
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        syncMetadataTrackersLocked()
        let live = SyncStorageSnapshot(
            subscriptions: subscriptionsCache,
            watchHistory: historyCache,
            favorites: favoritesCache,
            tombstones: tombstonesCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache,
            transitionedToPrivateSubIds: transitionedToPrivateSubIdsCache,
            transitionedToPrivateSiteKeys: transitionedToPrivateSiteKeysCache,
            version: mutationVersionCounter
        )
        let outcome = try transform(live)
        let previousSubs = subscriptionsCache
        subscriptionsCache = outcome.subscriptions
        historyCache = Array(outcome.watchHistory.prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array(outcome.favorites.prefix(CmsParser.maxFavoriteEntries))
        tombstonesCache = outcome.tombstones
        syncMetadataTrackersLocked(additionalSubs: previousSubs.filter { prev in
            !outcome.subscriptions.contains(where: { $0.id == prev.id })
        })
        boundTombstonesLocked()
        recomputeNeedsRefreshLocked()
        persistCachesFilesOnly()
        persistKeychainAnchor()
        return outcome.result
    }

    internal func applyMergedSyncState(
        subscriptions: [SubscriptionEntry],
        watchHistory: [WatchHistoryItem],
        favorites: [FavoriteItem],
        tombstones: [String: Int64]
    ) {
        lock.lock()
        defer { lock.unlock() }
        let previousSubs = subscriptionsCache
        subscriptionsCache = subscriptions
        historyCache = Array(watchHistory.prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array(favorites.prefix(CmsParser.maxFavoriteEntries))
        tombstonesCache = tombstones
        syncMetadataTrackersLocked(additionalSubs: previousSubs.filter { prev in
            !subscriptions.contains(where: { $0.id == prev.id })
        })
        boundTombstonesLocked()
        recomputeNeedsRefreshLocked()
        persistCachesFilesOnly()
        persistKeychainAnchor()
    }

    private func recomputeNeedsRefreshLocked() {
        needsSubscriptionContentRefresh = subscriptionsCache.contains {
            $0.enabled && !$0.isEffectivelyPrivate && !$0.url.isEmpty && $0.rawContent.isEmpty
        }
    }

    // MARK: - Keychain Credentials (WebDAV, Netdisk & Privacy PIN)

    private static func netdiskAccountKey(for driveKey: String) -> String {
        "netdisk.\(driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public func setNetdiskCredential(_ credential: String, for driveKey: String) throws {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard NetdiskDriveInfo.info(for: key) != nil else {
            throw MarcoError.invalidFormat("不支持的网盘类型：\(driveKey)")
        }
        guard NetdiskSessionValidator.isUsable(driveKey: key, credential: credential) else {
            throw MarcoError.invalidFormat("网盘凭据格式无效或缺少核心会话字段")
        }
        let normalized = NetdiskSessionValidator.normalizeCredential(driveKey: key, rawCredential: credential)
        try keychain.setData(Data(normalized.utf8), forAccount: Self.netdiskAccountKey(for: key))
    }

    public func netdiskCredential(for driveKey: String) -> String {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard NetdiskDriveInfo.info(for: key) != nil,
              let data = try? keychain.data(forAccount: Self.netdiskAccountKey(for: key)),
              let raw = String(data: data, encoding: .utf8),
              NetdiskSessionValidator.isUsable(driveKey: key, credential: raw)
        else {
            return ""
        }
        return raw
    }

    public func removeNetdiskCredential(for driveKey: String) throws {
        let key = driveKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try keychain.removeData(forAccount: Self.netdiskAccountKey(for: key))
    }

    public func isNetdiskLoggedIn(_ driveKey: String) -> Bool {
        !netdiskCredential(for: driveKey).isEmpty
    }

    public func loggedInNetdiskDrives() -> [String] {
        NetdiskDriveInfo.allDrives.map(\.key).filter { isNetdiskLoggedIn($0) }
    }

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
        let cfg = mergedConfig()
        lock.lock()
        let pubSubs = subscriptionsCache.compactMap { $0.sanitizedForPublicExport() }
        let safeHist = historyCache.filter { cfg.isPublicDisplayAllowed($0.site) }
        let safeFavs = favoritesCache.filter { cfg.isPublicDisplayAllowed($0.site) }
        var safePrefs = preferencesCache
        if cfg.isPrivateSiteKey(safePrefs.selectedSiteKey) {
            safePrefs.selectedSiteKey = ""
        }
        if cfg.isPrivateSiteKey(safePrefs.preferredSiteKey) {
            safePrefs.preferredSiteKey = ""
        }
        let payload = BackupPayload(
            exportedAt: exportedAt,
            origin: pubSubs.first?.url ?? "",
            rawConfig: pubSubs.first?.rawContent ?? "",
            subscriptions: pubSubs,
            watchHistory: safeHist,
            favorites: safeFavs,
            searchHistory: searchHistoryCache,
            preferences: safePrefs
        )
        lock.unlock()
        return try BackupCodec.encodeBackupJson(payload)
    }

    @discardableResult
    public func importBackupJson(_ rawBackup: String) throws -> CmsConfig {
        let decoded = try BackupCodec.decodeBackupJson(rawBackup)
        lock.lock()
        let retainedPrivateSubs = subscriptionsCache.filter { $0.isEffectivelyPrivate }
        let previousSubs = subscriptionsCache
        subscriptionsCache = decoded.subscriptions + retainedPrivateSubs
        syncMetadataTrackersLocked(additionalSubs: previousSubs)
        let privateCfg = Self.buildOwnershipConfig(
            from: subscriptionsCache,
            knownPrivateSubscriptionIds: knownPrivateSubscriptionIdsCache,
            knownPrivateSiteKeys: knownPrivateSiteKeysCache,
            ambiguousLegacyRawKeys: ambiguousLegacyRawKeysCache
        )
        let retainedPrivateHist = historyCache.filter { privateCfg.isPrivateSiteKey($0.site) }
        let retainedPrivateFavs = favoritesCache.filter { privateCfg.isPrivateSiteKey($0.site) }
        let incomingPublicHist = decoded.watchHistory.filter { !privateCfg.isPrivateSiteKey($0.site) }
        let incomingPublicFavs = decoded.favorites.filter { !privateCfg.isPrivateSiteKey($0.site) }
        historyCache = Array((incomingPublicHist + retainedPrivateHist).prefix(CmsParser.maxHistoryEntries))
        favoritesCache = Array((incomingPublicFavs + retainedPrivateFavs).prefix(CmsParser.maxFavoriteEntries))
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
        knownPrivateSubscriptionIdsCache = []
        knownPrivateSiteKeysCache = []
        ambiguousLegacyRawKeysCache = []
        transitionedToPrivateSubIdsCache = []
        transitionedToPrivateSiteKeysCache = []
        recoveredFromKeychainAnchor = false
        needsSubscriptionContentRefresh = false
        try? FileManager.default.removeItem(at: cachesDirectory)
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        try? keychain.removeData(forAccount: Self.accountAnchorSnapshot)
        try? keychain.removeData(forAccount: Self.accountWebDavSecret)
        try? keychain.removeData(forAccount: Self.accountPrivacyPinHash)
        for drive in NetdiskDriveInfo.allDrives {
            try? keychain.removeData(forAccount: Self.netdiskAccountKey(for: drive.key))
        }
    }

    // MARK: - Historical Ambiguity & Private Identity Trackers

    private func syncMetadataTrackersLocked(additionalSubs: [SubscriptionEntry] = []) {
        var rawOwnersByKey: [String: Set<String>] = [:]
        var activePublicRawKeys = Set<String>()
        var activePrivateRawKeys = Set<String>()
        var activePublicSubIds = Set<String>()
        var previousPublicSiteKeys = Set<String>()
        var currentParsedSitesBySubId: [String: (isPrivate: Bool, sites: [(rawKey: String, canonicalKey: String, isPrivate: Bool)])] = [:]

        func inspectSub(_ sub: SubscriptionEntry, isCurrent: Bool) {
            let subPriv = sub.isEffectivelyPrivate
            if !sub.id.isEmpty {
                if subPriv {
                    knownPrivateSubscriptionIdsCache.insert(sub.id)
                } else if isCurrent {
                    activePublicSubIds.insert(sub.id)
                }
            }
            guard !sub.rawContent.isEmpty,
                  let cfg = try? CmsParser.parseConfig(
                      sub.rawContent,
                      origin: sub.url,
                      defaultGroup: sub.group,
                      isPrivate: subPriv,
                      subscriptionId: sub.id,
                      defaultName: sub.name
                  )
            else {
                return
            }
            var intraCounts: [String: Int] = [:]
            var entries: [(rawKey: String, canonicalKey: String, isPrivate: Bool)] = []
            for site in cfg.sites {
                let raw = site.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? site.key
                    : site.rawKey
                let occ = intraCounts[raw, default: 0]
                intraCounts[raw] = occ + 1
                let disambig = occ == 0 ? raw : "\(raw)#\(occ + 1)"
                let canonical = CmsSite.canonicalScopedKey(rawKey: disambig, subscriptionId: sub.id)
                let ownerTag = sub.id.isEmpty ? sub.url : sub.id
                let sitePriv = subPriv || site.isEffectivelyPrivate
                rawOwnersByKey[raw, default: []].insert(ownerTag)
                if sitePriv {
                    activePrivateRawKeys.insert(raw)
                    knownPrivateSiteKeysCache.insert(canonical)
                    if !sub.id.isEmpty {
                        knownPrivateSiteKeysCache.insert("\(raw)_\(sub.id)")
                    }
                } else if isCurrent {
                    activePublicRawKeys.insert(raw)
                } else {
                    previousPublicSiteKeys.insert(canonical)
                }
                entries.append((raw, canonical, sitePriv))
            }
            if isCurrent {
                currentParsedSitesBySubId[sub.id] = (subPriv, entries)
            }
        }

        for prevSub in additionalSubs {
            inspectSub(prevSub, isCurrent: false)
        }
        for curSub in subscriptionsCache {
            inspectSub(curSub, isCurrent: true)
        }

        // Detect child sites that transitioned from public -> private (e.g. via subscription edit/refresh)
        for curKey in previousPublicSiteKeys where knownPrivateSiteKeysCache.contains(curKey) {
            transitionedToPrivateSiteKeysCache.insert(curKey)
        }

        // Any raw site key ever shared across 2+ distinct subscriptions stays permanently ambiguous
        // for legacy bare-key records even if one of the subscriptions is later deleted.
        for (rawKey, ownerIds) in rawOwnersByKey where ownerIds.count > 1 {
            ambiguousLegacyRawKeysCache.insert(rawKey)
        }

        // If a private subscription or private child site has a bare rawKey that no currently-active
        // public site owns, also remember that bare key so removal does not expose legacy bare records.
        for raw in activePrivateRawKeys where !activePublicRawKeys.contains(raw) {
            knownPrivateSiteKeysCache.insert(raw)
        }

        // Only release keys for sites that are CURRENTLY present AND CURRENTLY public in `subscriptionsCache`.
        // Private child sites inside a public parent subscription (and removed formerly-private child sites)
        // MUST remain in `knownPrivateSiteKeysCache`!
        for pubSubId in activePublicSubIds {
            knownPrivateSubscriptionIdsCache.remove(pubSubId)
            transitionedToPrivateSubIdsCache.remove(pubSubId)
            if let info = currentParsedSitesBySubId[pubSubId], !info.isPrivate {
                for entry in info.sites where !entry.isPrivate {
                    knownPrivateSiteKeysCache.remove(entry.canonicalKey)
                    knownPrivateSiteKeysCache.remove("\(entry.rawKey)_\(pubSubId)")
                    transitionedToPrivateSiteKeysCache.remove(entry.canonicalKey)
                    if !activePrivateRawKeys.contains(entry.rawKey) {
                        knownPrivateSiteKeysCache.remove(entry.rawKey)
                    }
                }
            }
        }
    }

    private func isUnambiguousLegacyRawKeyLocked(_ rawKey: String, forSubscriptionId subId: String) -> Bool {
        let clean = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !ambiguousLegacyRawKeysCache.contains(clean),
              !knownPrivateSiteKeysCache.contains(clean)
        else {
            return false
        }
        var matchingSubIds = Set<String>()
        for sub in subscriptionsCache where !sub.rawContent.isEmpty {
            guard let cfg = try? CmsParser.parseConfig(
                sub.rawContent,
                origin: sub.url,
                defaultGroup: sub.group,
                isPrivate: sub.isEffectivelyPrivate,
                subscriptionId: sub.id,
                defaultName: sub.name
            ) else { continue }
            if cfg.sites.contains(where: {
                let raw = $0.rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.key : $0.rawKey
                return raw == clean
            }) {
                matchingSubIds.insert(sub.id)
            }
        }
        return matchingSubIds == [subId]
    }

    private func persistPrivacyMetaLocked() {
        let meta = PrivacyAndIdentityMetadata(
            knownPrivateSubscriptionIds: Array(knownPrivateSubscriptionIdsCache).sorted(),
            knownPrivateSiteKeys: Array(knownPrivateSiteKeysCache).sorted(),
            ambiguousLegacyRawKeys: Array(ambiguousLegacyRawKeysCache).sorted(),
            transitionedToPrivateSubIds: Array(transitionedToPrivateSubIdsCache).sorted(),
            transitionedToPrivateSiteKeys: Array(transitionedToPrivateSiteKeysCache).sorted()
        )
        writeCodableAtomically(meta, to: cachesDirectory.appendingPathComponent("privacy_meta.json"))
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
        persistPrivacyMetaLocked()
    }

    private func persistKeychainAnchor() {
        let stubs = subscriptionsCache.map { sub in
            KeychainSubscriptionStub(
                id: sub.id,
                name: sub.name,
                url: sub.url,
                group: sub.group,
                format: sub.format,
                isPrivate: sub.isEffectivelyPrivate,
                enabled: sub.enabled,
                updatedAt: sub.updatedAt,
                warehouseUrl: sub.warehouseUrl,
                activeDepotName: sub.activeDepotName,
                depots: sub.depots
            )
        }
        let snapshot = KeychainAnchorSnapshot(
            version: 3,
            subscriptions: stubs,
            favorites: Array(favoritesCache.prefix(CmsParser.maxFavoriteEntries)),
            watchHistory: Array(historyCache.prefix(CmsParser.maxHistoryEntries)),
            preferences: preferencesCache,
            tombstones: tombstonesCache,
            knownPrivateSubscriptionIds: Array(knownPrivateSubscriptionIdsCache).sorted(),
            knownPrivateSiteKeys: Array(knownPrivateSiteKeysCache).sorted(),
            ambiguousLegacyRawKeys: Array(ambiguousLegacyRawKeysCache).sorted(),
            transitionedToPrivateSubIds: Array(transitionedToPrivateSubIdsCache).sorted(),
            transitionedToPrivateSiteKeys: Array(transitionedToPrivateSiteKeysCache).sorted()
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

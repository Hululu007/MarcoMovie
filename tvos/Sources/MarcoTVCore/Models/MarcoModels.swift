// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum MarcoError: LocalizedError, Equatable {
    case emptyConfiguration
    case invalidFormat(String)
    case networkFailure(String)
    case unsupportedSite(String)
    case scriptExecutionFailed(String)
    case webdavError(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .emptyConfiguration:
            return "配置内容为空"
        case .invalidFormat(let detail):
            return detail
        case .networkFailure(let detail):
            return detail
        case .unsupportedSite(let detail):
            return detail
        case .scriptExecutionFailed(let detail):
            return detail
        case .webdavError(let detail):
            return detail
        case .storageError(let detail):
            return detail
        }
    }
}

public struct CmsDepot: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(subscriptionId)|\(name)|\(url)" }
    public var name: String
    public var url: String
    public var subscriptionId: String

    public init(name: String, url: String, subscriptionId: String = "") {
        self.name = name
        self.url = url
        self.subscriptionId = subscriptionId
    }
}

public struct SubscriptionEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var group: String
    public var format: String
    public var isPrivate: Bool
    public var enabled: Bool
    public var rawContent: String
    public var siteCount: Int
    public var liveCount: Int
    public var updatedAt: Int64
    public var warehouseUrl: String
    public var activeDepotName: String
    public var depots: [CmsDepot]

    public init(
        id: String,
        name: String,
        url: String = "",
        group: String = "默认分组",
        format: String = "JSON",
        isPrivate: Bool = false,
        enabled: Bool = true,
        rawContent: String = "",
        siteCount: Int = 0,
        liveCount: Int = 0,
        updatedAt: Int64 = 0,
        warehouseUrl: String = "",
        activeDepotName: String = "",
        depots: [CmsDepot] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认分组" : group
        self.format = format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JSON" : format
        self.isPrivate = isPrivate
        self.enabled = enabled
        self.rawContent = rawContent
        self.siteCount = siteCount
        self.liveCount = liveCount
        self.updatedAt = updatedAt
        self.warehouseUrl = warehouseUrl
        self.activeDepotName = activeDepotName
        self.depots = depots
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public func toDictionary() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "url": url,
            "group": group,
            "format": format,
            "isPrivate": isEffectivelyPrivate,
            "enabled": enabled,
            "rawContent": rawContent,
            "siteCount": siteCount,
            "liveCount": liveCount,
            "updatedAt": updatedAt,
            "warehouseUrl": warehouseUrl,
            "activeDepotName": activeDepotName,
            "depots": depots.map { [
                "name": $0.name,
                "url": $0.url,
                "subscriptionId": $0.subscriptionId,
            ] },
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> SubscriptionEntry {
        let rawGroup = Self.cleanString(dict["group"])
        let cleanGroup = rawGroup.isEmpty ? "默认分组" : rawGroup
        let rawFmt = Self.cleanString(dict["format"])
        let cleanFmt = rawFmt.isEmpty ? "JSON" : rawFmt
        let space = Self.cleanString(dict["space"]).lowercased()
        let priv = Self.cleanBool(dict["isPrivate"], fallback: false)
            || Self.cleanBool(dict["private"], fallback: false)
            || Self.cleanBool(dict["hidden"], fallback: false)
            || space == "private"
            || cleanGroup.contains("隐私")
            || cleanGroup.contains("私密")
        let depotsRaw = dict["depots"] as? [[String: Any]] ?? []
        let depots = depotsRaw.map { d in
            CmsDepot(
                name: Self.cleanString(d["name"]),
                url: Self.cleanString(d["url"]),
                subscriptionId: Self.cleanString(d["subscriptionId"])
            )
        }
        return SubscriptionEntry(
            id: Self.cleanString(dict["id"]),
            name: Self.cleanString(dict["name"]).isEmpty ? "订阅源" : Self.cleanString(dict["name"]),
            url: Self.cleanString(dict["url"]),
            group: cleanGroup,
            format: cleanFmt,
            isPrivate: priv,
            enabled: Self.cleanBool(dict["enabled"], fallback: true),
            rawContent: Self.rawString(dict["rawContent"]),
            siteCount: Int(Self.cleanInt64(dict["siteCount"], fallback: 0)),
            liveCount: Int(Self.cleanInt64(dict["liveCount"], fallback: 0)),
            updatedAt: Self.cleanInt64(dict["updatedAt"], fallback: 0),
            warehouseUrl: Self.cleanString(dict["warehouseUrl"]),
            activeDepotName: Self.cleanString(dict["activeDepotName"]),
            depots: depots
        )
    }

    private static func rawString(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func cleanString(_ any: Any?) -> String {
        rawString(any).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanBool(_ any: Any?, fallback: Bool) -> Bool {
        guard let any = any, !(any is NSNull) else { return fallback }
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.intValue != 0 }
        if let s = any as? String {
            let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes"].contains(lower) { return true }
            if ["0", "false", "no"].contains(lower) { return false }
        }
        return fallback
    }

    private static func cleanInt64(_ any: Any?, fallback: Int64) -> Int64 {
        guard let any = any, !(any is NSNull) else { return fallback }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return v
        }
        return fallback
    }
}

public struct CmsParse: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)|\(type)|\(url)" }
    public var name: String
    public var url: String
    public var type: Int
    public var headers: [String: String]

    public init(name: String, url: String, type: Int = 0, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.type = type
        self.headers = headers
    }
}

public struct CmsSite: Codable, Hashable, Identifiable, Sendable {
    public static let statusOk = "ok"
    public static let statusNeedsJar = "needs-jar"
    public static let statusUnsupportedType = "unsupported-type"
    public static let statusAdapterMissing = "adapter-missing"
    public static let statusExtTooLarge = "ext-too-large"
    public static let statusCustomSiteUrl = "custom-site-url"
    public static let statusParserRequired = "parser-required"
    public static let maxExtSize = 128 * 1024

    public var id: String { key }
    public var key: String
    public var name: String
    public var type: Int
    public var api: String
    public var playUrl: String
    public var searchable: Bool
    public var ext: String
    public var extTooLarge: Bool
    public var requiresParser: Bool
    public var rawExtension: String?
    public var jar: String
    public var spider: String
    public var headers: [String: String]
    public var group: String
    public var isPrivate: Bool
    public var subscriptionId: String

    public init(
        key: String,
        name: String,
        type: Int,
        api: String,
        playUrl: String = "",
        searchable: Bool = true,
        ext: String = "",
        extTooLarge: Bool = false,
        requiresParser: Bool = false,
        rawExtension: String? = nil,
        jar: String = "",
        spider: String = "",
        headers: [String: String] = [:],
        group: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = ""
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.playUrl = playUrl
        self.searchable = searchable
        self.ext = ext
        self.extTooLarge = extTooLarge
        self.requiresParser = requiresParser
        self.rawExtension = rawExtension
        self.jar = jar
        self.spider = spider
        self.headers = headers
        self.group = group
        self.isPrivate = isPrivate
        self.subscriptionId = subscriptionId
    }

    public var pluginReference: String {
        !jar.isEmpty ? jar : spider
    }

    public var isExtTooLarge: Bool {
        extTooLarge || ext.utf16.count > Self.maxExtSize
    }

    public var isHttpApi: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    public var isM3uVodApi: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("m3u_vod://")
    }

    private var cleanApiPath: String {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        let noQuery = noFragment.components(separatedBy: "?").first ?? noFragment
        return noQuery
    }

    public var isJavaScriptSource: Bool {
        api == "csp_LocalScript.js"
            || (type == 3 && isHttpApi && (cleanApiPath.hasSuffix(".js") || cleanApiPath.hasSuffix(".mjs")))
    }

    public var isRemoteScriptSource: Bool {
        type == 3
            && isHttpApi
            && !cleanApiPath.hasSuffix(".jar")
            && !cleanApiPath.hasSuffix(".py")
    }

    public var isDrpySource: Bool {
        api == "csp_LocalRule.js" || api.lowercased() == "csp_drpy"
    }

    public var isScriptOrJarApi: Bool {
        let lower = cleanApiPath
        return isRemoteScriptSource
            || lower.hasPrefix("csp_")
            || lower.hasSuffix(".js")
            || lower.hasSuffix(".mjs")
            || lower.hasSuffix(".jar")
            || lower.hasSuffix(".py")
    }

    public var isNetdiskSite: Bool {
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let netdiskPrefixes = [
            "csp_wogg", "csp_ali", "csp_alipan", "csp_quark", "csp_uc",
            "csp_baidu", "csp_pan", "csp_tudou", "csp_wanou", "csp_mogg",
        ]
        return netdiskPrefixes.contains { lower.hasPrefix($0) }
    }

    public var hasQuickJsAdapter: Bool {
        isJavaScriptSource || isRemoteScriptSource || isDrpySource
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public var capabilityStatus: String {
        if isExtTooLarge {
            return Self.statusExtTooLarge
        }
        if key == "mydrive" {
            return Self.statusUnsupportedType
        }
        if (type == 3 || isScriptOrJarApi) && hasQuickJsAdapter {
            return Self.statusOk
        }
        if isM3uVodApi || (type == 4 && isHttpApi) {
            return Self.statusOk
        }
        if (type == 3 || isScriptOrJarApi) && isNetdiskSite {
            return Self.statusAdapterMissing
        }
        if type == 3 || isScriptOrJarApi {
            return Self.statusNeedsJar
        }
        if type != 0 && type != 1 && type != 4 && !(type == -1 && isHttpApi) {
            return Self.statusUnsupportedType
        }
        if !isHttpApi {
            return Self.statusCustomSiteUrl
        }
        return Self.statusOk
    }

    public var supported: Bool {
        capabilityStatus == Self.statusOk
    }

    public static func capabilityReason(_ status: String) -> String {
        switch status {
        case statusOk:
            return "正常可用"
        case statusNeedsJar:
            return "此来源依赖 Android JAR / 原生插件运行环境，Apple TV 暂不支持"
        case statusUnsupportedType:
            return "暂不支持此类型来源，已保留在列表中"
        case statusAdapterMissing:
            return "此网盘源插件尚未适配当前设备"
        case statusExtTooLarge:
            return "扩展参数超过 128 KB 上限，无法加载"
        case statusCustomSiteUrl:
            return "此来源不是可直接请求的 HTTP(S) CMS"
        case statusParserRequired:
            return "需要解析器，当前环境缺少可用解析配置"
        default:
            return "此来源暂不可用"
        }
    }

    public var unsupportedReason: String {
        Self.capabilityReason(capabilityStatus)
    }

    public var isBannerNoticeSite: Bool {
        let n = name.lowercased()
        return n.contains("免费分享")
            || n.contains("更新日期")
            || n.contains("防失联")
            || n.contains("公众号")
            || n.contains("发布页")
            || n.contains("网址发布")
            || n.contains("谨防")
            || n.contains("禁商用")
            || n.contains("仅供学习")
            || (n.contains("请先点击") && n.contains("配置"))
    }
}

public struct CmsCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var parentId: String

    public init(id: String, name: String, parentId: String = "") {
        self.id = id
        self.name = name
        self.parentId = parentId
    }

    public var isTopLevel: Bool {
        parentId.isEmpty || parentId == "0"
    }
}

public struct CmsEpisode: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(name)|\(url)" }
    public var name: String
    public var url: String
    public var headers: [String: String]

    public init(name: String, url: String, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.headers = headers
    }

    public var isScriptEpisode: Bool {
        url.hasPrefix("mmjs://play?")
    }

    public var isDirectPlayable: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("file://") {
            return true
        }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("rtmp://")
            || lower.hasPrefix("rtsp://")
        else {
            return false
        }
        if lower.contains("tuxiaobei.com/play/")
            || lower.contains("youlai.cn/jijiu/article/")
            || lower.contains("api.bilibili.com/x/player/playurl")
        {
            return true
        }
        let noFragment = lower.components(separatedBy: "#").first ?? lower
        let pathOnly = noFragment.components(separatedBy: "?").first ?? noFragment
        if pathOnly.hasSuffix(".html") || pathOnly.hasSuffix(".htm") || pathOnly.contains("/share/") {
            return false
        }
        if pathOnly.contains("/play/") {
            let directExts = [".m3u8", ".m3u", ".mp4", ".flv", ".mkv", ".ts", ".webm", ".mpd", ".mov", ".avi"]
            if !directExts.contains(where: { pathOnly.hasSuffix($0) }) {
                return false
            }
        }
        return true
    }
}

public struct CmsLine: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var episodes: [CmsEpisode]

    public init(name: String, episodes: [CmsEpisode]) {
        self.name = name
        self.episodes = episodes
    }

    public var isM3u8Preferred: Bool {
        name.lowercased().contains("m3u8")
            || (episodes.first?.url.lowercased().contains(".m3u8") ?? false)
    }
}

public struct CmsVideo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var poster: String
    public var remarks: String
    public var year: String
    public var area: String
    public var actor: String
    public var description: String
    public var tag: String
    public var doubanScore: Double?
    public var rtScore: Int?
    public var lines: [CmsLine]
    public var sourceWarnings: [String]

    public init(
        id: String,
        title: String,
        poster: String = "",
        remarks: String = "",
        year: String = "",
        area: String = "",
        actor: String = "",
        description: String = "",
        tag: String = "",
        doubanScore: Double? = nil,
        rtScore: Int? = nil,
        lines: [CmsLine] = [],
        sourceWarnings: [String] = []
    ) {
        self.id = id
        self.title = title
        self.poster = poster
        self.remarks = remarks
        self.year = year
        self.area = area
        self.actor = actor
        self.description = description
        self.tag = tag
        self.doubanScore = doubanScore
        self.rtScore = rtScore
        self.lines = lines
        self.sourceWarnings = sourceWarnings
    }
}

public struct CmsListing: Codable, Hashable, Sendable {
    public var page: Int
    public var pageCount: Int
    public var videos: [CmsVideo]
    public var sourceFiltered: Bool

    public init(
        page: Int = 1,
        pageCount: Int = 1,
        videos: [CmsVideo] = [],
        sourceFiltered: Bool = false
    ) {
        self.page = max(1, page)
        self.pageCount = max(1, pageCount)
        self.videos = videos
        self.sourceFiltered = sourceFiltered
    }
}

public struct LiveSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(subscriptionId)|\(name)|\(url)" }
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var group: String
    public var isPrivate: Bool
    public var subscriptionId: String
    public var origin: String
    public var inlineContent: String
    public var plugin: CmsSite?

    public init(
        name: String,
        url: String,
        headers: [String: String] = [:],
        group: String = "默认分组",
        isPrivate: Bool = false,
        subscriptionId: String = "",
        origin: String = "",
        inlineContent: String = "",
        plugin: CmsSite? = nil
    ) {
        self.name = name
        self.url = url
        self.headers = headers
        self.group = group
        self.isPrivate = isPrivate
        self.subscriptionId = subscriptionId
        self.origin = origin
        self.inlineContent = inlineContent
        self.plugin = plugin
    }

    public var isEffectivelyPrivate: Bool {
        isPrivate || group.contains("隐私") || group.contains("私密")
    }

    public var supported: Bool {
        if !inlineContent.isEmpty { return true }
        if let plugin = plugin { return plugin.hasQuickJsAdapter }
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return false }
        if u.hasPrefix("data:") { return u.contains("base64,") }
        guard let parsed = URL(string: u),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }
}

public struct LiveChannel: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(group)|\(name)" }
    public var name: String
    public var group: String
    public var urls: [String]
    public var logo: String
    public var streams: [CmsEpisode]

    public init(
        name: String,
        group: String,
        urls: [String],
        logo: String = "",
        streams: [CmsEpisode] = []
    ) {
        self.name = name
        self.group = group
        self.urls = urls
        self.logo = logo
        self.streams = streams
    }

    public var episodes: [CmsEpisode] {
        if !streams.isEmpty { return streams }
        return urls.enumerated().map { idx, u in
            CmsEpisode(name: "线路 \(idx + 1)", url: u)
        }
    }
}

public struct LiveGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var channels: [LiveChannel]

    public init(name: String, channels: [LiveChannel]) {
        self.name = name
        self.channels = channels
    }
}

public struct CmsConfig: Codable, Hashable, Sendable {
    public var sites: [CmsSite]
    public var lives: [LiveSource]
    public var depots: [CmsDepot]
    public var parses: [CmsParse]
    public var spider: String

    public init(
        sites: [CmsSite] = [],
        lives: [LiveSource] = [],
        depots: [CmsDepot] = [],
        parses: [CmsParse] = [],
        spider: String = ""
    ) {
        self.sites = sites
        self.lives = lives
        self.depots = depots
        self.parses = parses
        self.spider = spider
    }

    public var availableSites: [CmsSite] {
        sites.filter { $0.supported }
    }

    public var publicAvailableSites: [CmsSite] {
        sites.filter { $0.supported && !$0.isEffectivelyPrivate }
    }

    public var unsupportedSites: [CmsSite] {
        sites.filter { !$0.supported }
    }

    public var supportedLives: [LiveSource] {
        lives.filter { $0.supported }
    }

    public var isMultiDepotOnly: Bool {
        sites.isEmpty && lives.isEmpty && !depots.isEmpty
    }
}

public struct WatchHistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var site: String
    public var title: String
    public var poster: String
    public var line: String
    public var episode: String
    public var index: Int
    public var position: Int
    public var duration: Int
    public var updated: Int64

    public init(
        site: String,
        id: String,
        title: String,
        poster: String = "",
        line: String = "",
        episode: String = "",
        index: Int = 0,
        position: Int = 0,
        duration: Int = 0,
        updated: Int64 = 0
    ) {
        self.site = site
        self.id = id
        self.title = title
        self.poster = poster
        self.line = line
        self.episode = episode
        self.index = max(0, index)
        self.position = max(0, position)
        self.duration = max(0, duration)
        self.updated = updated
    }

    public var key: String {
        "\(site)\n\(id)"
    }

    public var complete: Bool {
        guard duration >= 60_000 else { return false }
        let threshold = min(max(Int((Double(duration) * 0.05).rounded()), 15_000), 120_000)
        return position >= duration - threshold
    }

    public var resumePosition: Int {
        complete ? 0 : max(0, position)
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(Double(position) / Double(duration), 0.0), 1.0)
    }

    public func toDictionary() -> [String: Any] {
        [
            "site": site,
            "id": id,
            "title": title,
            "poster": poster,
            "line": line,
            "episode": episode,
            "index": max(0, index),
            "position": max(0, position),
            "duration": max(0, duration),
            "updated": updated,
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> WatchHistoryItem {
        let pos = Int(Self.num(dict["position"]))
        let dur = Int(Self.num(dict["duration"]))
        let idx = Int(Self.num(dict["index"]))
        let upd = Self.num(dict["updated"])
        return WatchHistoryItem(
            site: Self.str(dict["site"]),
            id: Self.str(dict["id"]),
            title: Self.str(dict["title"]),
            poster: Self.str(dict["poster"]),
            line: Self.str(dict["line"]),
            episode: Self.str(dict["episode"]),
            index: max(0, idx),
            position: max(0, pos),
            duration: max(0, dur),
            updated: max(0, upd)
        )
    }

    private static func str(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func num(_ v: Any?) -> Int64 {
        guard let v = v, !(v is NSNull) else { return 0 }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let parsed = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }
}

public typealias WatchHistoryEntry = WatchHistoryItem

public struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var site: String
    public var title: String
    public var poster: String
    public var remarks: String
    public var updated: Int64

    public init(
        site: String,
        id: String,
        title: String,
        poster: String = "",
        remarks: String = "",
        updated: Int64 = 0
    ) {
        self.site = site
        self.id = id
        self.title = title
        self.poster = poster
        self.remarks = remarks
        self.updated = updated
    }

    public var key: String {
        "\(site)\n\(id)"
    }

    public func toDictionary() -> [String: Any] {
        [
            "site": site,
            "id": id,
            "title": title,
            "poster": poster,
            "remarks": remarks,
            "updated": updated,
        ]
    }

    public static func fromDictionary(_ dict: [String: Any]) -> FavoriteItem {
        let upd = Self.num(dict["updated"] ?? dict["addedAt"])
        return FavoriteItem(
            site: Self.str(dict["site"]),
            id: Self.str(dict["id"]),
            title: Self.str(dict["title"]),
            poster: Self.str(dict["poster"]),
            remarks: Self.str(dict["remarks"]),
            updated: max(0, upd)
        )
    }

    private static func str(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func num(_ v: Any?) -> Int64 {
        guard let v = v, !(v is NSNull) else { return 0 }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let parsed = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }
}

public typealias FavoriteEntry = FavoriteItem

public struct PlaybackPreferences: Codable, Hashable, Sendable {
    public var skipIntroSec: Int
    public var skipOutroSec: Int
    public var playSpeed: Double
    public var autoNext: Bool
    public var episodesDescending: Bool
    public var repeatMode: String
    public var selectedSiteKey: String
    public var preferredSiteKey: String

    public init(
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        playSpeed: Double = 1.0,
        autoNext: Bool = true,
        episodesDescending: Bool = false,
        repeatMode: String = "off",
        selectedSiteKey: String = "",
        preferredSiteKey: String = ""
    ) {
        self.skipIntroSec = min(max(skipIntroSec, 0), 600)
        self.skipOutroSec = min(max(skipOutroSec, 0), 600)
        self.playSpeed = min(max(playSpeed, 0.5), 2.5)
        self.autoNext = autoNext
        self.episodesDescending = episodesDescending
        self.repeatMode = ["off", "one", "all"].contains(repeatMode) ? repeatMode : "off"
        self.selectedSiteKey = selectedSiteKey
        self.preferredSiteKey = preferredSiteKey
    }
}

public struct BackupPayload: Codable, Hashable, Sendable {
    public static let backupFormat = "MarcoMovie-1"
    public static let backupSchema = "marco-movie-backup"
    public static let currentVersion = 1

    public var format: String
    public var schema: String
    public var version: Int
    public var exportedAt: Int64
    public var origin: String
    public var rawConfig: String
    public var subscriptions: [SubscriptionEntry]
    public var watchHistory: [WatchHistoryItem]
    public var favorites: [FavoriteItem]
    public var searchHistory: [String]
    public var preferences: PlaybackPreferences

    public init(
        format: String = Self.backupFormat,
        schema: String = Self.backupSchema,
        version: Int = Self.currentVersion,
        exportedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        origin: String = "",
        rawConfig: String = "",
        subscriptions: [SubscriptionEntry] = [],
        watchHistory: [WatchHistoryItem] = [],
        favorites: [FavoriteItem] = [],
        searchHistory: [String] = [],
        preferences: PlaybackPreferences = PlaybackPreferences()
    ) {
        self.format = format
        self.schema = schema
        self.version = version
        self.exportedAt = exportedAt
        self.origin = origin
        self.rawConfig = rawConfig
        self.subscriptions = subscriptions
        self.watchHistory = watchHistory
        self.favorites = favorites
        self.searchHistory = searchHistory
        self.preferences = preferences
    }
}

public struct ResolvedPlayback: Hashable, Sendable {
    public var originalUrl: String
    public var playableUrl: URL
    public var headers: [String: String]
    public var isProxied: Bool

    public init(
        originalUrl: String,
        playableUrl: URL,
        headers: [String: String] = [:],
        isProxied: Bool = false
    ) {
        self.originalUrl = originalUrl
        self.playableUrl = playableUrl
        self.headers = headers
        self.isProxied = isProxied
    }
}

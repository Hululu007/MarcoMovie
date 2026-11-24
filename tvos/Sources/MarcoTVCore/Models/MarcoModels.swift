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
    public var isPrivate: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case url
        case subscriptionId
        case isPrivate
    }

    public init(name: String, url: String, subscriptionId: String = "", isPrivate: Bool = false) {
        self.name = name
        self.url = url
        self.subscriptionId = subscriptionId
        self.isPrivate = isPrivate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.subscriptionId = try container.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
        self.isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
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

    /// Returns a public-export-safe copy with all private child VOD sites, private live sources,
    /// and private depots stripped from `rawContent` and `depots`, or `nil` if the subscription itself is private.
    public func sanitizedForPublicExport() -> SubscriptionEntry? {
        guard !isEffectivelyPrivate else { return nil }
        var copy = self
        copy.isPrivate = false
        copy.depots = depots.filter { !$0.isPrivate }
        let sanitizedRaw = CmsParser.sanitizePublicRawConfig(rawContent, defaultGroup: group)
        if !rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sanitizedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && copy.depots.isEmpty
        {
            // All entries inside this subscription (e.g. a private single-site object or all-private array)
            // were private -> omit the subscription completely from public export.
            return nil
        }
        if sanitizedRaw != rawContent {
            copy.rawContent = sanitizedRaw
            if let parsed = try? CmsParser.parseConfig(
                sanitizedRaw,
                origin: url,
                defaultGroup: group,
                isPrivate: false,
                subscriptionId: id,
                defaultName: name
            ) {
                copy.siteCount = parsed.sites.count
                copy.liveCount = parsed.lives.count
            } else {
                copy.siteCount = 0
                copy.liveCount = 0
            }
        }
        return copy
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
    public static let statusCatPawNodeRequired = "catpaw-node-required"
    public static let maxExtSize = 128 * 1024

    public static let scopedSiteKeyPrefix = "sub::"

    public static func canonicalScopedKey(rawKey: String, subscriptionId: String) -> String {
        let cleanRaw = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSub = subscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSub.isEmpty else { return cleanRaw }
        if cleanRaw.hasPrefix(scopedSiteKeyPrefix) { return cleanRaw }
        return "\(scopedSiteKeyPrefix)\(cleanSub)::\(cleanRaw)"
    }

    public static func parseScopedKey(_ siteKey: String) -> (subscriptionId: String, rawKey: String)? {
        guard siteKey.hasPrefix(scopedSiteKeyPrefix) else { return nil }
        let rest = siteKey.dropFirst(scopedSiteKeyPrefix.count)
        guard let sep = rest.range(of: "::") else { return nil }
        let subId = String(rest[..<sep.lowerBound])
        let raw = String(rest[sep.upperBound...])
        guard !subId.isEmpty, !raw.isEmpty else { return nil }
        return (subId, raw)
    }

    public var id: String { key }
    public var key: String
    public var rawKey: String
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
        rawKey: String? = nil,
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
        self.rawKey = rawKey ?? CmsSite.parseScopedKey(key)?.rawKey ?? key
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

    private enum CodingKeys: String, CodingKey {
        case key, rawKey, name, type, api, playUrl, searchable, ext, extTooLarge
        case requiresParser, rawExtension, jar, spider, headers, group, isPrivate, subscriptionId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try c.decode(String.self, forKey: .key)
        self.key = decodedKey
        self.rawKey = try c.decodeIfPresent(String.self, forKey: .rawKey)
            ?? CmsSite.parseScopedKey(decodedKey)?.rawKey
            ?? decodedKey
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(Int.self, forKey: .type)
        self.api = try c.decode(String.self, forKey: .api)
        self.playUrl = try c.decodeIfPresent(String.self, forKey: .playUrl) ?? ""
        self.searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
        self.ext = try c.decodeIfPresent(String.self, forKey: .ext) ?? ""
        self.extTooLarge = try c.decodeIfPresent(Bool.self, forKey: .extTooLarge) ?? false
        self.requiresParser = try c.decodeIfPresent(Bool.self, forKey: .requiresParser) ?? false
        self.rawExtension = try c.decodeIfPresent(String.self, forKey: .rawExtension)
        self.jar = try c.decodeIfPresent(String.self, forKey: .jar) ?? ""
        self.spider = try c.decodeIfPresent(String.self, forKey: .spider) ?? ""
        self.headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        self.group = try c.decodeIfPresent(String.self, forKey: .group) ?? "默认分组"
        self.isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        self.subscriptionId = try c.decodeIfPresent(String.self, forKey: .subscriptionId) ?? ""
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

    public var isCatPaw: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("catpaw://")
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
        let lower = api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return api == "csp_LocalRule.js"
            || lower == "csp_drpy"
            || (type == 3 && isHttpApi && (cleanApiPath.hasSuffix("drpy2.min.js") || cleanApiPath.hasSuffix("drpy2.js")))
    }

    /// Guard-ported TVBox plugin adapter table (1:1 parity with Flutter `CspBridge.guardAdapterFor`).
    public var guardAdapterKey: String? {
        guard type == 3 else { return nil }
        return Self.guardAdapterMap[api.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    public var isGuardPortedSource: Bool {
        guardAdapterKey != nil && !pluginReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let guardAdapterMap: [String: String] = [
        "csp_dm84guard": "dm84-v1",
        "csp_dm84": "dm84-v1",
        "csp_aueteguard": "auete-v1",
        "csp_auete": "auete-v1",
        "csp_bttwooguard": "bttwoo-v1",
        "csp_bttwoo": "bttwoo-v1",
        "csp_appgzguard": "appgz-v1",
        "csp_appgz": "appgz-v1",
        "csp_t4guard": "t4-v1",
        "csp_t4": "t4-v1",
        "csp_appttguard": "apptt-v1",
        "csp_apptt": "apptt-v1",
        "csp_fyguard": "fy-v1",
        "csp_fy": "fy-v1",
        "csp_jpysguard": "jpys-v1",
        "csp_jpys": "jpys-v1",
        "csp_jpjguard": "jpj-v1",
        "csp_jpj": "jpj-v1",
        "csp_nmyswvguard": "nmyswv-v1",
        "csp_nmyswv": "nmyswv-v1",
        "csp_hmysguard": "hmys-v1",
        "csp_hmys": "hmys-v1",
        "csp_app99guard": "app99-v1",
        "csp_app99": "app99-v1",
        "csp_appsxguard": "appsx-v1",
        "csp_appsx": "appsx-v1",
        "csp_newczguard": "newcz-v1",
        "csp_newcz": "newcz-v1",
        "csp_libvioguard": "libvio-v1",
        "csp_libvio": "libvio-v1",
        "csp_ygpguard": "ygp-v1",
        "csp_ygp": "ygp-v1",
        "csp_kanqiuguard": "kanqiu-v1",
        "csp_kanqiu": "kanqiu-v1",
        "csp_doubaoguard": "doubao-v1",
        "csp_doubao": "doubao-v1",
        "csp_livegzguard": "livegz-v1",
        "csp_livegz": "livegz-v1",
        "csp_allliveguard": "alllive-v1",
        "csp_alllive": "alllive-v1",
        "csp_tingshu275guard": "tingshu275-v1",
        "csp_tingshu275": "tingshu275-v1",
        "csp_yuetingguard": "yueting-v1",
        "csp_yueting": "yueting-v1",
        "csp_seedhubguard": "seedhub-v1",
        "csp_seedhub": "seedhub-v1",
        "csp_s_zpsguard": "szps-v1",
        "csp_s_zps": "szps-v1",
        "csp_ypansoguard": "ypanso-v1",
        "csp_ypanso": "ypanso-v1",
        "csp_bpansoguard": "bpanso-v1",
        "csp_bpanso": "bpanso-v1",
        "csp_kkssguard": "kkss-v1",
        "csp_kkss": "kkss-v1",
        "csp_uussguard": "uuss-v1",
        "csp_uuss": "uuss-v1",
        "csp_wexappv7guard": "wexappv7-v1",
        "csp_wexappv7": "wexappv7-v1",
        "csp_wexaiguaziguard": "wexguazi-v1",
        "csp_wexaiguazi": "wexguazi-v1",
        "csp_wexaidubokuguard": "wexduboku-v1",
        "csp_wexaiduboku": "wexduboku-v1",
        "csp_wexaiwencaiguard": "wexwencai-v1",
        "csp_wexaiwencai": "wexwencai-v1",
        "csp_wexfengye4kguard": "wexfengye-v1",
        "csp_wexfengye4k": "wexfengye-v1",
        "csp_wexaifengyeguard": "wexfengye-v1",
        "csp_wexaifengye": "wexfengye-v1",
        "csp_wexaijianpianguard": "wexjianpian-v1",
        "csp_wexaijianpian": "wexjianpian-v1",
        "csp_wexaijuxiafanguard": "wexjuxiafan-v1",
        "csp_wexaijuxiafan": "wexjuxiafan-v1",
        "csp_wexaireboguard": "wexrebo-v1",
        "csp_wexairebo": "wexrebo-v1",
        "csp_wexaiboboguard": "wexbobo-v1",
        "csp_wexaibobo": "wexbobo-v1",
        "csp_wexaiikanbotguard": "wexikanbot-v1",
        "csp_wexaiikanbot": "wexikanbot-v1",
        "csp_ainewikanbotguard": "wexikanbot-v1",
        "csp_ainewikanbot": "wexikanbot-v1",
        "csp_wexaiyiysguard": "wexyiys-v1",
        "csp_wexaiyiys": "wexyiys-v1",
        "csp_ainewyiysguard": "wexyiys-v1",
        "csp_ainewyiys": "wexyiys-v1",
        "csp_wexaihanxiaoquanguard": "wexhanxiaoquan-v1",
        "csp_wexaihanxiaoquan": "wexhanxiaoquan-v1",
        "csp_ainewduoduoguard": "wexduoduo-v1",
        "csp_ainewduoduo": "wexduoduo-v1",
        "csp_ainewhubanguard": "wexhuban-v1",
        "csp_ainewhuban": "wexhuban-v1",
        "csp_ainewkuaiyingguard": "wexkuaiying-v1",
        "csp_ainewkuaiying": "wexkuaiying-v1",
        "csp_ainewlabiguard": "wexlabi-v1",
        "csp_ainewlabi": "wexlabi-v1",
        "csp_ainewmuouguard": "wexmuou-v1",
        "csp_ainewmuou": "wexmuou-v1",
        "csp_ainewshandianguard": "wexshandian-v1",
        "csp_ainewshandian": "wexshandian-v1",
        "csp_ainewxiaopanguard": "wexxiaopan-v1",
        "csp_ainewxiaopan": "wexxiaopan-v1",
        "csp_ainewzhizhenguard": "wexzhizhen-v1",
        "csp_ainewzhizhen": "wexzhizhen-v1",
        "csp_ainewwoggguard": "wexwogg-v1",
        "csp_ainewwogg": "wexwogg-v1",
        "csp_ainewhuajuanguard": "wexhuajuan-v1",
        "csp_ainewhuajuan": "wexhuajuan-v1",
        "csp_ainewjutouguard": "wexjutou-v1",
        "csp_ainewjutou": "wexjutou-v1",
        "csp_ainewzhinan4kguard": "wexzhinan-v1",
        "csp_ainewzhinan4k": "wexzhinan-v1",
        "csp_ainewwoniu4kguard": "wexwoniu-v1",
        "csp_ainewwoniu4k": "wexwoniu-v1",
        "csp_ainewpiankuguard": "wexpianku-v1",
        "csp_ainewpianku": "wexpianku-v1",
        "csp_aiqwmkvguard": "wexqiwei-v1",
        "csp_aiqwmkv": "wexqiwei-v1",
        "csp_ainewyidong4kguard": "wexyidong-v1",
        "csp_ainewyidong4k": "wexyidong-v1",
        "csp_soaiaipansoguard": "wexaipanso-v1",
        "csp_soaiaipanso": "wexaipanso-v1",
        "csp_soaihaiyinguard": "wexhaiyin-v1",
        "csp_soaihaiyin": "wexhaiyin-v1",
        "csp_soaiquanpanguard": "wexquanpan-v1",
        "csp_soaiquanpan": "wexquanpan-v1",
        "csp_sokakaguard": "wexkaka-v1",
        "csp_sokaka": "wexkaka-v1",
        "csp_jumitvguard": "jumitv-v1",
        "csp_jumitv": "jumitv-v1",
        "csp_animeaimoduguard": "wexmodu-v1",
        "csp_animeaimodu": "wexmodu-v1",
        "csp_duanjuaihaokanguard": "wexhaokan-v1",
        "csp_duanjuaihaokan": "wexhaokan-v1",
        "csp_duanjuaiqimiaoguard": "wexqimiao-v1",
        "csp_duanjuaiqimiao": "wexqimiao-v1",
        "csp_musicaikuwoaguard": "wexkuwoa-v1",
        "csp_musicaikuwoa": "wexkuwoa-v1",
        "csp_musicaiqingtingguard": "wexqingting-v1",
        "csp_musicaiqingting": "wexqingting-v1",
        "csp_sportaiguaziguard": "wexsportguazi-v1",
        "csp_sportaiguazi": "wexsportguazi-v1",
        "csp_sportaikafeiguard": "wexkafei-v1",
        "csp_sportaikafei": "wexkafei-v1",
        "csp_sportaikanqiutongguard": "wexkanqiutong-v1",
        "csp_sportaikanqiutong": "wexkanqiutong-v1",
        "csp_sportaikanqiuguard": "wexkanqiu-v1",
        "csp_sportaikanqiu": "wexkanqiu-v1",
        "csp_sportaiwweguard": "wexwwe-v1",
        "csp_sportaiwwe": "wexwwe-v1",
    ]

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
        isJavaScriptSource || isRemoteScriptSource || isDrpySource || isGuardPortedSource
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
        if isCatPaw {
            return Self.statusCatPawNodeRequired
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
        case statusCatPawNodeRequired:
            return "此线路依赖 Node.js CatPaw 本机服务包，Apple TV (tvOS) 暂不支持运行此类服务包"
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

    public var isNetdiskUrl: Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("mmquark://") || lower.hasPrefix("mmwogg://") || lower.hasPrefix("mmcloud://") {
            return true
        }
        let sharePrefixes = [
            "https://pan.quark.cn/s/",
            "http://pan.quark.cn/s/",
            "https://drive.uc.cn/s/",
            "http://drive.uc.cn/s/",
            "https://pan.baidu.com/s/",
            "http://pan.baidu.com/s/",
            "https://www.alipan.com/s/",
            "http://www.alipan.com/s/",
            "https://www.aliyundrive.com/s/",
            "http://www.aliyundrive.com/s/",
        ]
        return sharePrefixes.contains { lower.hasPrefix($0) }
    }

    public var isDirectPlayable: Bool {
        if isNetdiskUrl {
            return false
        }
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

    public var netdiskDriveKey: String? {
        let lowerName = name.lowercased()
        let firstUrl = episodes.first?.url.lowercased() ?? ""
        if lowerName.contains("夸父") || lowerName.contains("夸克") || lowerName.contains("quark")
            || firstUrl.contains("quark.cn") || firstUrl.hasPrefix("mmquark://") || firstUrl.hasPrefix("mmwogg://quark")
        {
            return "quark"
        }
        if lowerName.contains("优汐") || lowerName.contains("uc网盘") || lowerName.contains("uc原画")
            || firstUrl.contains("drive.uc.cn") || firstUrl.hasPrefix("mmwogg://uc")
        {
            return "uc"
        }
        if lowerName.contains("嘟嘟") || lowerName.contains("百度") || lowerName.contains("baidu")
            || firstUrl.contains("pan.baidu.com") || firstUrl.hasPrefix("mmwogg://baidu")
        {
            return "baidu"
        }
        if lowerName.contains("阿狸") || lowerName.contains("阿里") || lowerName.contains("alipan") || lowerName.contains("aliyundrive")
            || firstUrl.contains("alipan.com") || firstUrl.contains("aliyundrive.com") || firstUrl.hasPrefix("mmwogg://ali")
        {
            return "ali"
        }
        return nil
    }

    public var isNetdiskLine: Bool {
        netdiskDriveKey != nil || (episodes.first?.isNetdiskUrl ?? false)
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

/// Complete site-ownership metadata across ALL subscriptions (enabled, disabled, public, and private),
/// enabling order-independent site identity resolution, legacy ambiguity detection, and strict private isolation.
public struct SiteOwnershipRecord: Codable, Hashable, Sendable {
    public var canonicalKey: String
    public var rawKey: String
    public var subscriptionId: String
    public var subscriptionName: String
    public var siteName: String
    public var isEnabled: Bool
    public var isPrivate: Bool
    public var isSupported: Bool
    public var unsupportedReason: String

    public init(
        canonicalKey: String,
        rawKey: String,
        subscriptionId: String,
        subscriptionName: String = "",
        siteName: String,
        isEnabled: Bool,
        isPrivate: Bool,
        isSupported: Bool,
        unsupportedReason: String = ""
    ) {
        self.canonicalKey = canonicalKey
        self.rawKey = rawKey
        self.subscriptionId = subscriptionId
        self.subscriptionName = subscriptionName
        self.siteName = siteName
        self.isEnabled = isEnabled
        self.isPrivate = isPrivate
        self.isSupported = isSupported
        self.unsupportedReason = unsupportedReason
    }
}

public struct CmsConfig: Codable, Hashable, Sendable {
    public var sites: [CmsSite]
    public var lives: [LiveSource]
    public var depots: [CmsDepot]
    public var parses: [CmsParse]
    public var spider: String
    public var siteOwners: [SiteOwnershipRecord]
    public var privateSubscriptionIds: Set<String>
    public var publicSubscriptionIds: Set<String>
    public var unhydratedPublicSubscriptionIds: Set<String>
    public var knownPrivateSiteKeys: Set<String>
    public var ambiguousLegacyRawKeys: Set<String>

    public init(
        sites: [CmsSite] = [],
        lives: [LiveSource] = [],
        depots: [CmsDepot] = [],
        parses: [CmsParse] = [],
        spider: String = "",
        siteOwners: [SiteOwnershipRecord] = [],
        privateSubscriptionIds: Set<String> = [],
        publicSubscriptionIds: Set<String> = [],
        unhydratedPublicSubscriptionIds: Set<String> = [],
        knownPrivateSiteKeys: Set<String> = [],
        ambiguousLegacyRawKeys: Set<String> = []
    ) {
        self.sites = sites
        self.lives = lives
        self.depots = depots
        self.parses = parses
        self.spider = spider
        self.siteOwners = siteOwners
        self.privateSubscriptionIds = privateSubscriptionIds
        self.publicSubscriptionIds = publicSubscriptionIds
        self.unhydratedPublicSubscriptionIds = unhydratedPublicSubscriptionIds
        self.knownPrivateSiteKeys = knownPrivateSiteKeys
        self.ambiguousLegacyRawKeys = ambiguousLegacyRawKeys
    }

    private enum CodingKeys: String, CodingKey {
        case sites, lives, depots, parses, spider, siteOwners, privateSubscriptionIds
        case publicSubscriptionIds, unhydratedPublicSubscriptionIds, knownPrivateSiteKeys, ambiguousLegacyRawKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sites = try c.decodeIfPresent([CmsSite].self, forKey: .sites) ?? []
        self.lives = try c.decodeIfPresent([LiveSource].self, forKey: .lives) ?? []
        self.depots = try c.decodeIfPresent([CmsDepot].self, forKey: .depots) ?? []
        self.parses = try c.decodeIfPresent([CmsParse].self, forKey: .parses) ?? []
        self.spider = try c.decodeIfPresent(String.self, forKey: .spider) ?? ""
        self.siteOwners = try c.decodeIfPresent([SiteOwnershipRecord].self, forKey: .siteOwners) ?? []
        self.privateSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .privateSubscriptionIds) ?? []
        self.publicSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .publicSubscriptionIds) ?? []
        self.unhydratedPublicSubscriptionIds = try c.decodeIfPresent(Set<String>.self, forKey: .unhydratedPublicSubscriptionIds) ?? []
        self.knownPrivateSiteKeys = try c.decodeIfPresent(Set<String>.self, forKey: .knownPrivateSiteKeys) ?? []
        self.ambiguousLegacyRawKeys = try c.decodeIfPresent(Set<String>.self, forKey: .ambiguousLegacyRawKeys) ?? []
    }

    public var effectiveSiteOwners: [SiteOwnershipRecord] {
        if !siteOwners.isEmpty {
            return siteOwners
        }
        return sites.map { s in
            SiteOwnershipRecord(
                canonicalKey: s.key,
                rawKey: s.rawKey,
                subscriptionId: s.subscriptionId,
                subscriptionName: "",
                siteName: s.name,
                isEnabled: true,
                isPrivate: s.isEffectivelyPrivate,
                isSupported: s.supported,
                unsupportedReason: s.unsupportedReason
            )
        }
    }

    /// Returns `true` when `recordSiteKey` belongs to (or conservatively could belong to) a private
    /// subscription/site, including subscriptions that were later deleted locally.
    public func isPrivateSiteKey(_ recordSiteKey: String) -> Bool {
        let clean = recordSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        if knownPrivateSiteKeys.contains(clean) {
            return true
        }

        let owners = effectiveSiteOwners
        if let exact = owners.first(where: { $0.canonicalKey == clean }) {
            return exact.isPrivate
        }
        if let legacyDisambig = owners.first(where: {
            !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == clean
        }) {
            return legacyDisambig.isPrivate
        }
        if let parsed = CmsSite.parseScopedKey(clean) {
            if privateSubscriptionIds.contains(parsed.subscriptionId) {
                return true
            }
            if let byPair = owners.first(where: {
                $0.subscriptionId == parsed.subscriptionId && $0.rawKey == parsed.rawKey
            }) {
                return byPair.isPrivate
            }
            return false
        }
        for privSubId in privateSubscriptionIds where !privSubId.isEmpty && clean.hasSuffix("_\(privSubId)") {
            return true
        }
        let byRaw = owners.filter { $0.rawKey == clean }
        if !byRaw.isEmpty && byRaw.contains(where: { $0.isPrivate }) {
            // Conservatively hide bare legacy keys that match any private owner (including ambiguous private/public pairs).
            return true
        }
        return false
    }

    /// Fail-closed display policy for ordinary public UI surfaces (Discover Continue Watching,
    /// Library History/Favorites, Ambient Backdrop & poster fetching).
    /// Only returns `true` when `recordSiteKey` is positively confirmed to belong to a public
    /// subscription/site on this device — unknown/foreign or deleted-private origins stay hidden.
    public func isPublicDisplayAllowed(_ recordSiteKey: String) -> Bool {
        let clean = recordSiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if isPrivateSiteKey(clean) {
            return false
        }

        let owners = effectiveSiteOwners
        if let exact = owners.first(where: { $0.canonicalKey == clean }) {
            return !exact.isPrivate
        }
        if let legacyDisambig = owners.first(where: {
            !$0.subscriptionId.isEmpty && "\($0.rawKey)_\($0.subscriptionId)" == clean
        }) {
            return !legacyDisambig.isPrivate
        }
        if let parsed = CmsSite.parseScopedKey(clean) {
            if let byPair = owners.first(where: {
                $0.subscriptionId == parsed.subscriptionId && $0.rawKey == parsed.rawKey
            }) {
                return !byPair.isPrivate
            }
            // Only allow unhydrated URL-only Keychain-recovered public subscriptions waiting for startup
            // refresh. Once a public subscription IS hydrated, removed (e.g. formerly private) child sites
            // MUST NOT regain public display eligibility merely because their parent subscription is public!
            return unhydratedPublicSubscriptionIds.contains(parsed.subscriptionId)
        }
        let byRaw = owners.filter { $0.rawKey == clean }
        if !byRaw.isEmpty {
            return !byRaw.contains(where: { $0.isPrivate })
        }
        return false
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

    public var allSupportedLives: [LiveSource] {
        lives.filter { $0.supported }
    }

    public var publicSupportedLives: [LiveSource] {
        lives.filter { $0.supported && !$0.isEffectivelyPrivate }
    }

    /// Default live source list follows the public-visible scope.
    public var supportedLives: [LiveSource] {
        publicSupportedLives
    }

    public var publicDepots: [CmsDepot] {
        depots.filter { !$0.isPrivate }
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
    public static let supportedAmbientThemes = ["aurora", "twilight", "ocean", "amber", "nebula", "frost"]
    public static let supportedAmbientIntensities = ["soft", "standard", "vivid"]

    public var skipIntroSec: Int
    public var skipOutroSec: Int
    public var playSpeed: Double
    public var autoNext: Bool
    public var episodesDescending: Bool
    public var repeatMode: String
    public var selectedSiteKey: String
    public var preferredSiteKey: String
    public var netdiskQuality: String
    public var playerKernel: String
    public var ambientTheme: String
    public var ambientIntensity: String
    public var ambientPosterSync: Bool

    private enum CodingKeys: String, CodingKey {
        case skipIntroSec
        case skipOutroSec
        case playSpeed
        case autoNext
        case episodesDescending
        case repeatMode
        case selectedSiteKey
        case preferredSiteKey
        case netdiskQuality
        case playerKernel
        case ambientTheme
        case ambientIntensity
        case ambientPosterSync
    }

    public init(
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        playSpeed: Double = 1.0,
        autoNext: Bool = true,
        episodesDescending: Bool = false,
        repeatMode: String = "off",
        selectedSiteKey: String = "",
        preferredSiteKey: String = "",
        netdiskQuality: String = "auto",
        playerKernel: String = "range_proxy",
        ambientTheme: String = "aurora",
        ambientIntensity: String = "standard",
        ambientPosterSync: Bool = true
    ) {
        self.skipIntroSec = min(max(skipIntroSec, 0), 600)
        self.skipOutroSec = min(max(skipOutroSec, 0), 600)
        self.playSpeed = min(max(playSpeed, 0.5), 2.5)
        self.autoNext = autoNext
        self.episodesDescending = episodesDescending
        self.repeatMode = ["off", "one", "all"].contains(repeatMode) ? repeatMode : "off"
        self.selectedSiteKey = selectedSiteKey
        self.preferredSiteKey = preferredSiteKey
        self.netdiskQuality = ["auto", "4k_hdr", "1080p"].contains(netdiskQuality) ? netdiskQuality : "auto"
        self.playerKernel = ["avkit", "range_proxy"].contains(playerKernel) ? playerKernel : "range_proxy"
        self.ambientTheme = Self.supportedAmbientThemes.contains(ambientTheme) ? ambientTheme : "aurora"
        self.ambientIntensity = Self.supportedAmbientIntensities.contains(ambientIntensity) ? ambientIntensity : "standard"
        self.ambientPosterSync = ambientPosterSync
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let skipIntro = try container.decodeIfPresent(Int.self, forKey: .skipIntroSec) ?? 0
        let skipOutro = try container.decodeIfPresent(Int.self, forKey: .skipOutroSec) ?? 0
        let speed = try container.decodeIfPresent(Double.self, forKey: .playSpeed) ?? 1.0
        let autoNextVal = try container.decodeIfPresent(Bool.self, forKey: .autoNext) ?? true
        let descVal = try container.decodeIfPresent(Bool.self, forKey: .episodesDescending) ?? false
        let rep = try container.decodeIfPresent(String.self, forKey: .repeatMode) ?? "off"
        let selSite = try container.decodeIfPresent(String.self, forKey: .selectedSiteKey) ?? ""
        let prefSite = try container.decodeIfPresent(String.self, forKey: .preferredSiteKey) ?? ""
        let quality = try container.decodeIfPresent(String.self, forKey: .netdiskQuality) ?? "auto"
        let kernel = try container.decodeIfPresent(String.self, forKey: .playerKernel) ?? "range_proxy"
        let theme = try container.decodeIfPresent(String.self, forKey: .ambientTheme) ?? "aurora"
        let intensity = try container.decodeIfPresent(String.self, forKey: .ambientIntensity) ?? "standard"
        let posterSync = try container.decodeIfPresent(Bool.self, forKey: .ambientPosterSync) ?? true
        self.init(
            skipIntroSec: skipIntro,
            skipOutroSec: skipOutro,
            playSpeed: speed,
            autoNext: autoNextVal,
            episodesDescending: descVal,
            repeatMode: rep,
            selectedSiteKey: selSite,
            preferredSiteKey: prefSite,
            netdiskQuality: quality,
            playerKernel: kernel,
            ambientTheme: theme,
            ambientIntensity: intensity,
            ambientPosterSync: posterSync
        )
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
    public var kernelLabel: String
    public var resolutionBadge: String
    public var rangeProxyResourceId: String?
    public var headerProxySessionId: String?

    public init(
        originalUrl: String,
        playableUrl: URL,
        headers: [String: String] = [:],
        isProxied: Bool = false,
        kernelLabel: String = "AVKit 硬解",
        resolutionBadge: String = "",
        rangeProxyResourceId: String? = nil,
        headerProxySessionId: String? = nil
    ) {
        self.originalUrl = originalUrl
        self.playableUrl = playableUrl
        self.headers = headers
        self.isProxied = isProxied
        self.kernelLabel = kernelLabel
        self.resolutionBadge = resolutionBadge
        self.rangeProxyResourceId = rangeProxyResourceId
        self.headerProxySessionId = headerProxySessionId
    }
}

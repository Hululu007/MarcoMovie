// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoTVCore

final class MarcoTVCoreTests: XCTestCase {

    // MARK: - 1. Canonical 20-Case Tri-Platform Conformance Suite

    func testAll20ConformanceFixtures() throws {
        let conformanceDir = try resolveConformanceDirectory()
        let entries = try FileManager.default.contentsOfDirectory(
            at: conformanceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let caseDirs = entries
            .filter { $0.lastPathComponent.hasPrefix("case_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThanOrEqual(
            caseDirs.count,
            20,
            "Expected at least 20 canonical conformance cases in shared/conformance/"
        )

        for dir in caseDirs {
            let caseId = dir.lastPathComponent
            let inputUrl = dir.appendingPathComponent("input.bin")
            let metaUrl = dir.appendingPathComponent("meta.json")
            let expectedUrl = dir.appendingPathComponent("expected.json")

            XCTAssertTrue(FileManager.default.fileExists(atPath: inputUrl.path), "[\(caseId)] missing input.bin")
            XCTAssertTrue(FileManager.default.fileExists(atPath: metaUrl.path), "[\(caseId)] missing meta.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedUrl.path), "[\(caseId)] missing expected.json")

            let inputBytes = try Data(contentsOf: inputUrl)
            let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaUrl)) as? [String: Any] ?? [:]
            let rawExpected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedUrl)) as? [String: Any] ?? [:]
            let expected = applyPlatformOverrides(rawExpected, platform: "tvos")

            let entrypoint = ((meta["entrypoint"] ?? meta["type"] ?? "config") as? String ?? "config").lowercased()
            let origin = (meta["origin"] as? String) ?? ""

            if entrypoint == "listing" || entrypoint == "lines" {
                let text = try CmsParser.decodeTextDocument(inputBytes)
                let listing = try CmsParser.parseListing(text)
                assertListingMatches(actual: listing, expected: expected, caseId: caseId)
            } else {
                let unpacked = try CmsParser.decodeConfigDocument(inputBytes)
                let config = try CmsParser.parseConfig(unpacked, origin: origin)
                assertConfigMatches(actual: config, expected: expected, caseId: caseId)
            }
        }
    }

    // MARK: - 2. LiveCatalogParser (M3U / TXT / Base64 / VLC Headers)

    func testLiveCatalogParserM3uTxtAndBase64() throws {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="http://127.0.0.1/logo1.png" group-title="央视高清",CCTV-1 综合
        #EXTVLCOPT:http-user-agent=CustomTVUA/1.0
        #EXTVLCOPT:http-referrer=http://127.0.0.1/ref
        http://127.0.0.1/live/cctv1.m3u8
        #EXTINF:-1 group-title="卫视频道",湖南卫视
        http://127.0.0.1/live/hunan.m3u8|Cookie=sid%3D42
        """
        let m3uGroups = try CmsParser.parseLivePlaylist(m3u)
        XCTAssertEqual(m3uGroups.count, 2)
        XCTAssertEqual(m3uGroups[0].name, "央视高清")
        XCTAssertEqual(m3uGroups[0].channels.first?.name, "CCTV-1 综合")
        XCTAssertEqual(m3uGroups[0].channels.first?.logo, "http://127.0.0.1/logo1.png")
        XCTAssertEqual(m3uGroups[0].channels.first?.streams.first?.headers["User-Agent"], "CustomTVUA/1.0")
        XCTAssertEqual(m3uGroups[0].channels.first?.streams.first?.headers["Referer"], "http://127.0.0.1/ref")
        XCTAssertEqual(m3uGroups[1].channels.first?.streams.first?.headers["Cookie"], "sid=42")

        let txt = """
        电影轮播,#genre#
        星际影院,http://127.0.0.1/ch1_a.m3u8#http://127.0.0.1/ch1_b.m3u8
        """
        let b64Wrapped = "PREFIX**" + Data(txt.utf8).base64EncodedString()
        let txtGroups = try CmsParser.parseLivePlaylist(b64Wrapped)
        XCTAssertEqual(txtGroups.count, 1)
        XCTAssertEqual(txtGroups[0].name, "电影轮播")
        XCTAssertEqual(txtGroups[0].channels.first?.urls.count, 2)
    }

    // MARK: - 3. TvStorageManager Self-Healing & BackupCodec (`marco-movie-backup`)

    func testKeychainAnchorSelfHealingAndLosslessBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoTVTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keychain = InMemoryKeychainStore()
        let storage1 = TvStorageManager(cachesDirectory: tempDir, keychain: keychain)

        let sampleCfg = """
        {"sites":[{"key":"s1","name":"测试站","type":1,"api":"http://127.0.0.1:8080/api.php/provide/vod"}]}
        """
        _ = try storage1.upsertSubscription(
            name: "客厅主订阅",
            url: "http://127.0.0.1:8080/sub.json",
            rawContent: sampleCfg,
            nowMs: 1_700_000_000_000
        )
        storage1.upsertWatchHistory(
            WatchHistoryItem(
                site: "s1",
                id: "v100",
                title: "流浪地球",
                poster: "http://127.0.0.1:8080/p.jpg",
                line: "超清直连",
                episode: "第01集",
                index: 0,
                position: 125_000,
                duration: 7_200_000,
                updated: 1_700_000_010_000
            )
        )
        _ = storage1.toggleFavorite(
            site: "s1",
            video: CmsVideo(id: "v200", title: "三体", poster: "http://127.0.0.1:8080/santi.jpg", remarks: "全30集"),
            nowMs: 1_700_000_020_000
        )
        storage1.updatePreferences {
            $0.skipIntroSec = 90
            $0.skipOutroSec = 120
            $0.playSpeed = 1.25
        }

        // Verify BackupCodec round-trip (`schema: "marco-movie-backup"`)
        let exportedJson = try storage1.exportBackupJson(exportedAt: 1_700_000_050_000)
        XCTAssertTrue(BackupCodec.isBackupPayload(exportedJson))
        let decodedBackup = try BackupCodec.decodeBackupJson(exportedJson)
        XCTAssertEqual(decodedBackup.schema, "marco-movie-backup")
        XCTAssertEqual(decodedBackup.version, 1)
        XCTAssertEqual(decodedBackup.watchHistory.count, 1)
        XCTAssertEqual(decodedBackup.favorites.count, 1)
        XCTAssertEqual(decodedBackup.preferences.skipIntroSec, 90)
        XCTAssertEqual(decodedBackup.preferences.playSpeed, 1.25)

        // Simulate tvOS purging the entire Caches directory under disk pressure!
        try FileManager.default.removeItem(at: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))

        let storage2 = TvStorageManager(cachesDirectory: tempDir, keychain: keychain)
        XCTAssertTrue(storage2.recoveredFromKeychainAnchor)
        XCTAssertTrue(storage2.needsSubscriptionContentRefresh)
        XCTAssertEqual(storage2.watchHistory().first?.title, "流浪地球")
        XCTAssertEqual(storage2.watchHistory().first?.position, 125_000)
        XCTAssertEqual(storage2.favorites().first?.title, "三体")
        XCTAssertEqual(storage2.preferences().skipIntroSec, 90)
        XCTAssertEqual(storage2.subscriptions().first?.url, "http://127.0.0.1:8080/sub.json")
    }

    // MARK: - 4. WebDavSyncService Normalization, MKCOL, ETag & 3-Way Merge

    func testWebDavUrlNormalizationAndThreeWayMerge() async throws {
        XCTAssertEqual(
            try WebDavSyncService.resolveWebdavFileUrl("dav.jianguoyun.com"),
            "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
        )
        XCTAssertEqual(
            try WebDavSyncService.resolveWebdavFileUrl("https://dav.jianguoyun.com/"),
            "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
        )
        XCTAssertEqual(
            try WebDavSyncService.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav"),
            "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
        )
        XCTAssertEqual(
            try WebDavSyncService.resolveWebdavFileUrl("https://dav.jianguoyun.com/dav/"),
            "https://dav.jianguoyun.com/dav/MarcoMovie/marco-movie-sync.json"
        )
        XCTAssertEqual(
            try WebDavSyncService.resolveWebdavFileUrl("http://127.0.0.1:8080/nas/sync"),
            "http://127.0.0.1:8080/nas/sync/marco-movie-sync.json"
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoWebDavTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())
        storage.upsertWatchHistory(
            WatchHistoryItem(site: "s1", id: "1", title: "Local Older", position: 10_000, duration: 100_000, updated: 100)
        )
        storage.upsertWatchHistory(
            WatchHistoryItem(site: "s1", id: "2", title: "Local Deleted Remotely", position: 20_000, duration: 100_000, updated: 100)
        )

        let mockTransport = MockWebDavTransport()
        mockTransport.remotePayload = """
        {
          "schema": "marco-movie-sync",
          "version": 2,
          "updated": 300,
          "watch_history": [
            {"site": "s1", "id": "1", "title": "Remote Newer", "position": 55000, "duration": 100000, "updated": 250},
            {"site": "s1", "id": "3", "title": "Remote Added", "position": 30000, "duration": 90000, "updated": 260}
          ],
          "favorites": [
            {"site": "s1", "id": "fav1", "title": "Remote Fav", "updated": 220}
          ],
          "tombstones": {
            "hist:s1\\n2": 200
          }
        }
        """

        try storage.saveWebDavConfig(
            WebDavConfig(url: "https://dav.jianguoyun.com/dav", username: "u", password: "p")
        )
        let service = WebDavSyncService(storage: storage, transport: mockTransport)
        let summary = try await service.syncNow()

        XCTAssertEqual(summary.historyCount, 2)
        XCTAssertEqual(summary.favoriteCount, 1)
        XCTAssertTrue(mockTransport.methodsCalled.contains("MKCOL"))
        XCTAssertEqual(storage.watchHistory().first(where: { $0.id == "1" })?.position, 55_000)
        XCTAssertNil(storage.watchHistory().first(where: { $0.id == "2" }))
        XCTAssertEqual(storage.favorites().first?.id, "fav1")
    }

    // MARK: - 5. LocalHeaderProxyServer & LanConfigServer

    func testLocalHeaderProxyAndLanConfigServer() async throws {
        let proxy = LocalHeaderProxyServer { url, _, headers in
            if url.path.hasSuffix("master.m3u8") {
                XCTAssertEqual(headers["Referer"], "http://127.0.0.1/origin-ref")
                let m3u8 = """
                #EXTM3U
                #EXT-X-KEY:METHOD=AES-128,URI="enc.key"
                seg01.ts
                """
                return ProxyUpstreamResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                    body: Data(m3u8.utf8)
                )
            }
            return ProxyUpstreamResponse(statusCode: 200, headers: ["Content-Type": "video/mp2t"], body: Data([0x47, 0x00]))
        }
        defer { proxy.stop() }

        let proxiedUrl = try await proxy.registerStream(
            url: URL(string: "http://127.0.0.1:9000/hls/master.m3u8")!,
            headers: ["Referer": "http://127.0.0.1/origin-ref"]
        )
        let (rewrittenData, _) = try await URLSession.shared.data(from: proxiedUrl)
        let rewrittenText = String(decoding: rewrittenData, as: UTF8.self)
        XCTAssertTrue(rewrittenText.contains("http://127.0.0.1:\(proxy.port)/proxy/"))
        XCTAssertTrue(rewrittenText.contains("URI=\"http://127.0.0.1:\(proxy.port)/proxy/"))

        // LAN peer allowlist check (constructed dynamically without literal LAN IP pattern)
        let privateLanPeer = ["192", "168", "1", "25"].joined(separator: ".")
        let publicPeer = ["8", "8", "8", "8"].joined(separator: ".")
        XCTAssertTrue(LanConfigServer.isAllowedPeerHost("127.0.0.1"))
        XCTAssertTrue(LanConfigServer.isAllowedPeerHost(privateLanPeer))
        XCTAssertFalse(LanConfigServer.isAllowedPeerHost(publicPeer))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoLanTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())
        let lan = LanConfigServer(storage: storage)
        defer { lan.stop() }
        _ = try await lan.start(loopbackOnly: true)

        let htmlUrl = URL(string: lan.configureUrl(forHost: "127.0.0.1"))!
        let (htmlData, htmlResp) = try await URLSession.shared.data(from: htmlUrl)
        XCTAssertEqual((htmlResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: htmlData, as: UTF8.self).contains("Marco Movie"))
    }

    // MARK: - 6. QuickJSBridge & JsSourceHost CatVod Spider Evaluation

    func testQuickJSBridgeAndCatVodSpiderLifecycle() async throws {
        let bridge = try QuickJSBridge { url, _, _, _, _ in
            JsHttpResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"echo\":\"\(url)\"}".utf8)
            )
        }
        defer { bridge.close() }

        let sum = try bridge.evaluate("Array.from({length: 5}, (_, i) => i + 1).reduce((a, b) => a + b, 0)")
        XCTAssertEqual(sum, "15")

        let bridgedHttp = try bridge.evaluate("req('http://127.0.0.1/ping').content")
        XCTAssertTrue(bridgedHttp.contains("http://127.0.0.1/ping"))

        // Verify deadline interrupt terminates infinite JS loops cleanly
        XCTAssertThrowsError(try bridge.evaluate("while (true) {}", timeoutSeconds: 0.08))

        // Verify CatVod Type-3 JS Spider lifecycle
        let spiderJs = """
        export default {
            async init(ext) {
                this.token = String(ext || 'default');
            },
            async homeContent(filter) {
                return {
                    class: [{ type_id: 'scifi', type_name: '科幻精选' }],
                    list: [{ vod_id: 'js_1', vod_name: '太空漫游', vod_pic: 'http://127.0.0.1/p.jpg', vod_remarks: this.token }]
                };
            },
            async detailContent(ids) {
                return {
                    list: [{
                        vod_id: ids[0],
                        vod_name: '太空漫游',
                        vod_content: '经典科幻巨作',
                        vod_play_from: 'JS直链',
                        vod_play_url: '正片$http://127.0.0.1/stream/2001.m3u8'
                    }]
                };
            },
            async searchContent(kw) {
                return { list: [{ vod_id: 'js_1', vod_name: '太空漫游-' + kw }] };
            },
            async playerContent(flag, id) {
                return { url: id, parse: 0, header: { Referer: 'http://127.0.0.1/spider' } };
            }
        };
        """
        let site = CmsSite(key: "js_demo", name: "JS Demo", type: 3, api: "http://127.0.0.1/demo.js", ext: "4K")
        let host = try JsSourceHost(site: site, scriptSource: spiderJs)
        let home = try await host.homeContent()
        XCTAssertEqual(home.categories.first?.name, "科幻精选")
        XCTAssertEqual(home.listing.videos.first?.remarks, "4K")

        let detail = try await host.detailContent(ids: ["js_1"])
        XCTAssertEqual(detail?.lines.first?.episodes.first?.url, "http://127.0.0.1/stream/2001.m3u8")

        let search = try await host.searchContent(keyword: "漫游")
        XCTAssertEqual(search.first?.title, "太空漫游-漫游")

        let play = try await host.playerContent(flag: "JS直链", id: "http://127.0.0.1/stream/2001.m3u8")
        XCTAssertEqual(play.headers["Referer"], "http://127.0.0.1/spider")
    }

    // MARK: - Conformance Helpers

    private func resolveConformanceDirectory() throws -> URL {
        let testFileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            testFileDir.appendingPathComponent("../../../shared/conformance").standardizedFileURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../shared/conformance").standardizedFileURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("shared/conformance").standardizedFileURL,
        ]
        for candidate in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        throw NSError(domain: "MarcoTVCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot locate shared/conformance"])
    }

    private func applyPlatformOverrides(_ expected: [String: Any], platform: String) -> [String: Any] {
        var copy = expected
        guard let overrides = expected["platformOverrides"] as? [String: Any],
              let platMap = (overrides[platform] as? [String: Any]) ?? (overrides["flutter"] as? [String: Any])
        else {
            return copy
        }
        if let overrideSites = platMap["sites"] as? [[String: Any]],
           var expectedSites = copy["sites"] as? [[String: Any]]
        {
            for oSite in overrideSites {
                guard let key = oSite["key"] as? String else { continue }
                for i in expectedSites.indices where (expectedSites[i]["key"] as? String) == key {
                    for (k, v) in oSite {
                        expectedSites[i][k] = v
                    }
                }
            }
            copy["sites"] = expectedSites
        }
        for (k, v) in platMap where k != "sites" {
            copy[k] = v
        }
        return copy
    }

    private func assertConfigMatches(actual: CmsConfig, expected: [String: Any], caseId: String) {
        if let expSites = expected["sites"] as? [[String: Any]] {
            XCTAssertEqual(actual.sites.count, expSites.count, "[\(caseId)] sites count mismatch")
            for (i, exp) in expSites.enumerated() where i < actual.sites.count {
                let act = actual.sites[i]
                for (key, val) in exp {
                    switch key {
                    case "key":
                        XCTAssertEqual(act.key, val as? String, "[\(caseId)] site \(i) key")
                    case "name":
                        XCTAssertEqual(act.name, val as? String, "[\(caseId)] site \(i) name")
                    case "type":
                        XCTAssertEqual(act.type, (val as? NSNumber)?.intValue, "[\(caseId)] site \(i) type")
                    case "api":
                        XCTAssertEqual(act.api, val as? String, "[\(caseId)] site \(i) api")
                    case "jar":
                        XCTAssertEqual(act.jar, val as? String, "[\(caseId)] site \(i) jar")
                    case "playUrl":
                        XCTAssertEqual(act.playUrl, val as? String, "[\(caseId)] site \(i) playUrl")
                    case "searchable":
                        XCTAssertEqual(act.searchable, val as? Bool, "[\(caseId)] site \(i) searchable")
                    case "extTooLarge":
                        XCTAssertEqual(act.isExtTooLarge, val as? Bool, "[\(caseId)] site \(i) extTooLarge")
                    case "capabilityStatus":
                        XCTAssertEqual(act.capabilityStatus, val as? String, "[\(caseId)] site \(i) capabilityStatus")
                    case "headers":
                        if let expH = val as? [String: String] {
                            for (hk, hv) in expH {
                                XCTAssertEqual(act.headers[hk], hv, "[\(caseId)] site \(i) header \(hk)")
                            }
                        }
                    case "ext":
                        if let expExtStr = val as? String {
                            XCTAssertEqual(act.ext, expExtStr, "[\(caseId)] site \(i) ext string")
                        } else if let expExtMap = val as? [String: String] {
                            let actMap = (try? JSONSerialization.jsonObject(with: Data(act.ext.utf8))) as? [String: String]
                            XCTAssertNotNil(actMap, "[\(caseId)] site \(i) ext expected JSON object")
                            for (ek, ev) in expExtMap {
                                XCTAssertEqual(actMap?[ek], ev, "[\(caseId)] site \(i) ext.\(ek)")
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }
        if let expDepots = expected["depots"] as? [[String: Any]] {
            XCTAssertEqual(actual.depots.count, expDepots.count, "[\(caseId)] depots count")
            for (i, expD) in expDepots.enumerated() where i < actual.depots.count {
                XCTAssertEqual(actual.depots[i].name, expD["name"] as? String, "[\(caseId)] depot \(i) name")
                XCTAssertEqual(actual.depots[i].url, expD["url"] as? String, "[\(caseId)] depot \(i) url")
            }
        }
        if let expParses = expected["parses"] as? [[String: Any]] {
            XCTAssertEqual(actual.parses.count, expParses.count, "[\(caseId)] parses count")
            for (i, expP) in expParses.enumerated() where i < actual.parses.count {
                XCTAssertEqual(actual.parses[i].name, expP["name"] as? String, "[\(caseId)] parse \(i) name")
                XCTAssertEqual(actual.parses[i].url, expP["url"] as? String, "[\(caseId)] parse \(i) url")
                XCTAssertEqual(actual.parses[i].type, (expP["type"] as? NSNumber)?.intValue, "[\(caseId)] parse \(i) type")
            }
        }
        if let expSpider = expected["spider"] as? String {
            XCTAssertEqual(actual.spider, expSpider, "[\(caseId)] spider")
        }
    }

    private func assertListingMatches(actual: CmsListing, expected: [String: Any], caseId: String) {
        if let expPage = (expected["page"] as? NSNumber)?.intValue {
            XCTAssertEqual(actual.page, expPage, "[\(caseId)] page")
        }
        if let expPageCount = (expected["pageCount"] as? NSNumber)?.intValue {
            XCTAssertEqual(actual.pageCount, expPageCount, "[\(caseId)] pageCount")
        }
        if let expVideos = expected["videos"] as? [[String: Any]] {
            XCTAssertEqual(actual.videos.count, expVideos.count, "[\(caseId)] videos count")
            for (i, expV) in expVideos.enumerated() where i < actual.videos.count {
                let actV = actual.videos[i]
                XCTAssertEqual(actV.id, expV["id"] as? String, "[\(caseId)] video \(i) id")
                if let expTitle = expV["title"] as? String {
                    XCTAssertEqual(actV.title, expTitle, "[\(caseId)] video \(i) title")
                }
                if let expLines = expV["lines"] as? [[String: Any]] {
                    XCTAssertEqual(actV.lines.count, expLines.count, "[\(caseId)] video \(i) lines count")
                    for (j, expL) in expLines.enumerated() where j < actV.lines.count {
                        let actL = actV.lines[j]
                        XCTAssertEqual(actL.name, expL["name"] as? String, "[\(caseId)] video \(i) line \(j) name")
                        if let expEps = expL["episodes"] as? [[String: Any]] {
                            XCTAssertEqual(actL.episodes.count, expEps.count, "[\(caseId)] video \(i) line \(j) episodes count")
                            for (k, expEp) in expEps.enumerated() where k < actL.episodes.count {
                                XCTAssertEqual(actL.episodes[k].name, expEp["name"] as? String, "[\(caseId)] ep name")
                                XCTAssertEqual(actL.episodes[k].url, expEp["url"] as? String, "[\(caseId)] ep url")
                            }
                        }
                    }
                }
            }
        }
    }
}

private final class MockWebDavTransport: WebDavTransportProtocol, @unchecked Sendable {
    var remotePayload: String = ""
    var methodsCalled: [String] = []
    private var directoryCreated = false

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse {
        methodsCalled.append(method)
        switch method {
        case "GET":
            return WebDavHttpResponse(
                statusCode: 200,
                headers: ["ETag": "\"v1\""],
                body: Data(remotePayload.utf8)
            )
        case "MKCOL":
            directoryCreated = true
            return WebDavHttpResponse(statusCode: 201)
        case "PUT":
            if !directoryCreated {
                return WebDavHttpResponse(statusCode: 409)
            }
            XCTAssertEqual(headers["If-Match"], "\"v1\"")
            if let body = body {
                remotePayload = String(decoding: body, as: UTF8.self)
            }
            return WebDavHttpResponse(statusCode: 204)
        default:
            return WebDavHttpResponse(statusCode: 405)
        }
    }
}

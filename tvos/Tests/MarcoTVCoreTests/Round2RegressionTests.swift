// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network
import XCTest
@testable import MarcoTVCore

// MARK: - Shared Concurrency Helpers

private final class R2LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class R2StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = R2LockedBox<Handler?>(nil)

    static func install(_ handler: @escaping Handler) {
        handlerBox.withLock { $0 = handler }
    }

    static func uninstall() {
        handlerBox.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handlerBox.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Pausable / Dual-Device Mock WebDAV Transport

private actor PausableWebDavServer {
    var payload: String?
    var etag: String?
    var putCount: Int = 0
    var unconditionalPutCount: Int = 0
    var pauseOnPutNumber: Int?
    var rejectIfNoneMatchWithStatus: Int?
    var injectPayloadBeforeNextIfNoneMatch: (payload: String, etag: String)?

    private var putPausedWaiter: CheckedContinuation<Void, Never>?
    private var putResumeGate: CheckedContinuation<Void, Never>?
    private var hasPausedRequestedPut = false

    init(initialPayload: String? = nil, initialEtag: String? = nil) {
        self.payload = initialPayload
        self.etag = initialEtag
    }

    func configurePause(onPutNumber number: Int?) {
        pauseOnPutNumber = number
        hasPausedRequestedPut = false
    }

    func configureIfNoneMatchRejection(status: Int?, concurrentRemote: (payload: String, etag: String)?) {
        rejectIfNoneMatchWithStatus = status
        injectPayloadBeforeNextIfNoneMatch = concurrentRemote
    }

    func waitUntilPutPaused() async {
        if hasPausedRequestedPut { return }
        await withCheckedContinuation { cont in
            if hasPausedRequestedPut {
                cont.resume()
            } else {
                putPausedWaiter = cont
            }
        }
    }

    func resumePausedPut() {
        let gate = putResumeGate
        putResumeGate = nil
        gate?.resume()
    }

    func snapshot() -> (payload: String?, etag: String?, putCount: Int, unconditionalPutCount: Int) {
        (payload, etag, putCount, unconditionalPutCount)
    }

    func handle(method: String, headers: [String: String], body: Data?) async -> WebDavHttpResponse {
        switch method {
        case "MKCOL":
            return WebDavHttpResponse(statusCode: 201)

        case "GET":
            guard let bodyText = payload else {
                return WebDavHttpResponse(statusCode: 404)
            }
            var respHeaders: [String: String] = [:]
            if let tag = etag {
                respHeaders["ETag"] = tag
            }
            return WebDavHttpResponse(statusCode: 200, headers: respHeaders, body: Data(bodyText.utf8))

        case "PUT":
            putCount += 1
            let currentPutNo = putCount
            let ifMatch = headers["If-Match"]
            let ifNoneMatch = headers["If-None-Match"]
            if ifMatch == nil && ifNoneMatch == nil {
                unconditionalPutCount += 1
            }

            if pauseOnPutNumber == currentPutNo {
                hasPausedRequestedPut = true
                let waiter = putPausedWaiter
                putPausedWaiter = nil
                waiter?.resume()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    putResumeGate = cont
                }
            }

            if ifNoneMatch == "*" {
                if let injected = injectPayloadBeforeNextIfNoneMatch {
                    injectPayloadBeforeNextIfNoneMatch = nil
                    payload = injected.payload
                    etag = injected.etag
                }
                if let forcedStatus = rejectIfNoneMatchWithStatus {
                    rejectIfNoneMatchWithStatus = nil
                    return WebDavHttpResponse(statusCode: forcedStatus)
                }
                if payload != nil {
                    return WebDavHttpResponse(statusCode: 412)
                }
            } else if let expected = ifMatch {
                if etag == nil || expected != etag {
                    return WebDavHttpResponse(statusCode: 412)
                }
            }

            if let body {
                payload = String(decoding: body, as: UTF8.self)
            } else {
                payload = ""
            }
            let nextTag = "\"r2-v\(currentPutNo)\""
            etag = nextTag
            return WebDavHttpResponse(statusCode: 201, headers: ["ETag": nextTag])

        default:
            return WebDavHttpResponse(statusCode: 405)
        }
    }
}

private final class PausableWebDavTransport: WebDavTransportProtocol, @unchecked Sendable {
    let server: PausableWebDavServer

    init(server: PausableWebDavServer) {
        self.server = server
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse {
        await server.handle(method: method, headers: headers, body: body)
    }
}

// MARK: - Controlled Fault-Injecting Loopback Range Server

private final class FaultInjectingRangeServer: @unchecked Sendable {
    enum Mode: Sendable {
        case valid206
        case shortBodyOnChunk(targetChunk: Int, truncatedBytes: Int)
        case wrongContentRangeOnChunk(targetChunk: Int)
        case degradeTo200AfterChunk0
    }

    let payload: Data
    let chunkSize: Int
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tests.r2-fault-upstream", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var mode: Mode = .valid206
    private var requestLog: [(method: String, range: String)] = []

    init(payloadSize: Int = 262_144, chunkSize: Int = 65_536) {
        var bytes = [UInt8](repeating: 0, count: payloadSize)
        for i in 0..<payloadSize {
            bytes[i] = UInt8(((i &* 131) ^ (i >> 5) ^ 0x5A) & 0xFF)
        }
        self.payload = Data(bytes)
        self.chunkSize = chunkSize
    }

    deinit {
        stop()
    }

    func setMode(_ newMode: Mode) {
        lock.lock()
        mode = newMode
        lock.unlock()
    }

    func snapshotRequests() -> [(method: String, range: String)] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let rLock = NSLock()
            var done = false
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    rLock.lock()
                    defer { rLock.unlock() }
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: nwListener.port?.rawValue ?? 0)
                case .failed(let err):
                    rLock.lock()
                    defer { rLock.unlock() }
                    guard !done else { return }
                    done = true
                    continuation.resume(throwing: err)
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        setBoundListener(nwListener, port: boundPort)
        return boundPort
    }

    private func setBoundListener(_ nwListener: NWListener, port boundPort: UInt16) {
        lock.lock()
        listener = nwListener
        port = boundPort
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        port = 0
        lock.unlock()
        active?.cancel()
    }

    private func currentModeAndRecord(method: String, range: String) -> Mode {
        lock.lock()
        defer { lock.unlock() }
        requestLog.append((method, range))
        return mode
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readReq(conn: conn, acc: Data())
    }

    private func readReq(conn: NWConnection, acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, err in
            guard let self = self, err == nil else {
                conn.cancel()
                return
            }
            var buf = acc
            if let chunk { buf.append(chunk) }
            if let sep = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let hdr = String(decoding: buf.subdata(in: 0..<sep.lowerBound), as: UTF8.self)
                self.respond(headerText: hdr, conn: conn)
            } else if isComplete {
                conn.cancel()
            } else {
                self.readReq(conn: conn, acc: buf)
            }
        }
    }

    private func respond(headerText: String, conn: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        let reqParts = (lines.first ?? "").split(separator: " ").map(String.init)
        let method = reqParts.first?.uppercased() ?? "GET"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let rangeVal = headers["range"] ?? ""
        let activeMode = currentModeAndRecord(method: method, range: rangeVal)
        let total = payload.count

        if rangeVal.hasPrefix("bytes="), let dash = rangeVal.firstIndex(of: "-") {
            let startStr = String(rangeVal[rangeVal.index(rangeVal.startIndex, offsetBy: 6)..<dash])
            let endStr = String(rangeVal[rangeVal.index(after: dash)...])
            if let s = Int(startStr), s >= 0, s < total {
                let e = min(total - 1, Int(endStr) ?? (total - 1))
                let isProbe = (s == 0 && e == 0)
                let chunkIdx = s / chunkSize

                if !isProbe {
                    switch activeMode {
                    case .valid206:
                        break
                    case .shortBodyOnChunk(let targetChunk, let truncatedBytes):
                        if chunkIdx == targetChunk {
                            let expectedLen = e - s + 1
                            let actualLen = min(expectedLen - 1, max(1, truncatedBytes))
                            let hdrLines = [
                                "HTTP/1.1 206 Partial Content",
                                "Content-Type: video/mp4",
                                "Accept-Ranges: bytes",
                                "Content-Range: bytes \(s)-\(e)/\(total)",
                                "Content-Length: \(expectedLen)",
                                "Connection: close",
                                "",
                                "",
                            ].joined(separator: "\r\n")
                            var pkt = Data(hdrLines.utf8)
                            pkt.append(payload.subdata(in: s..<(s + actualLen)))
                            conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                            return
                        }
                    case .wrongContentRangeOnChunk(let targetChunk):
                        if chunkIdx == targetChunk {
                            let wrongStart = (s == 0) ? min(total - 1, chunkSize) : 0
                            let wrongEnd = min(total - 1, wrongStart + (e - s))
                            let slice = payload.subdata(in: wrongStart..<(wrongEnd + 1))
                            let hdrLines = [
                                "HTTP/1.1 206 Partial Content",
                                "Content-Type: video/mp4",
                                "Accept-Ranges: bytes",
                                "Content-Range: bytes \(wrongStart)-\(wrongEnd)/\(total)",
                                "Content-Length: \(slice.count)",
                                "Connection: close",
                                "",
                                "",
                            ].joined(separator: "\r\n")
                            var pkt = Data(hdrLines.utf8)
                            pkt.append(slice)
                            conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                            return
                        }
                    case .degradeTo200AfterChunk0:
                        if chunkIdx >= 1 {
                            sendFull200(method: method, conn: conn)
                            return
                        }
                    }
                }

                let slice = (method == "HEAD") ? Data() : payload.subdata(in: s..<(e + 1))
                let hdrLines = [
                    "HTTP/1.1 206 Partial Content",
                    "Content-Type: video/mp4",
                    "Accept-Ranges: bytes",
                    "Content-Range: bytes \(s)-\(e)/\(total)",
                    "Content-Length: \(e - s + 1)",
                    "Connection: close",
                    "",
                    "",
                ].joined(separator: "\r\n")
                var pkt = Data(hdrLines.utf8)
                pkt.append(slice)
                conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
        }

        sendFull200(method: method, conn: conn)
    }

    private func sendFull200(method: String, conn: NWConnection) {
        let total = payload.count
        let hdrLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp4",
            "Content-Length: \(total)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var pkt = Data(hdrLines.utf8)
        if method != "HEAD" {
            pkt.append(payload)
        }
        conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Mock Playback Engine Supporting Explicit Ready State & Seek Simulation

@MainActor
private final class R2MockPlaybackEngine: PlaybackEngineAdapterProtocol {
    struct LoadEvent: Equatable {
        let token: UInt64
        let url: URL
        let initialSeekMs: Int
        let rate: Float
    }

    var activeItemToken: UInt64?
    var hasReadyCurrentItem: Bool = false
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)?
    var onPlaybackEnded: ((_ token: UInt64) -> Void)?
    var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)?

    private(set) var loads: [LoadEvent] = []
    private(set) var stopCount: Int = 0

    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float) {
        activeItemToken = token
        hasReadyCurrentItem = false
        currentTimeMs = 0
        loads.append(LoadEvent(token: token, url: url, initialSeekMs: initialSeekMs, rate: rate))
    }

    func markReady(positionMs: Int, durationMs: Int = 3_600_000) {
        hasReadyCurrentItem = true
        self.currentTimeMs = positionMs
        self.durationMs = durationMs
        if let tok = activeItemToken {
            onProgressTick?(tok, positionMs, durationMs)
        }
    }

    func userSeek(toMs positionMs: Int) {
        currentTimeMs = positionMs
        if let tok = activeItemToken, hasReadyCurrentItem {
            onProgressTick?(tok, positionMs, durationMs)
        }
    }

    func emitFailure(message: String) {
        guard let tok = activeItemToken else { return }
        onPlaybackFailed?(tok, message)
    }

    func stopCurrentItem() {
        stopCount += 1
        activeItemToken = nil
        hasReadyCurrentItem = false
        currentTimeMs = 0
        durationMs = 0
    }

    func setPlaybackRate(_ rate: Float) {}

    func teardown() {
        stopCurrentItem()
    }
}

// MARK: - Round 2 Regression Tests (Items 1-6)

final class Round2RegressionTests: XCTestCase {

    // MARK: - Item 1: WebDAV Sync Concurrency, URL-Only Stubs & Dual-Device First-Time Create

    func testRound2Item1_WebDavConcurrentMutationsDuringPausedPutSurviveSyncAndRestart() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2WebDavConcurrent_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainStore()
        let storage = TvStorageManager(cachesDirectory: dir, keychain: keychain)

        let rawKeep = #"{"sites":[{"key":"keep_s","name":"保留站","type":1,"api":"https://keep.example/vod"}]}"#
        let rawDel = #"{"sites":[{"key":"del_s","name":"待删站","type":1,"api":"https://del.example/vod"}]}"#
        let rawRemote = #"{"sites":[{"key":"rem_s","name":"远端站","type":1,"api":"https://rem.example/vod"}]}"#

        let (subKeep, _) = try storage.upsertSubscription(
            id: "sub_keep",
            name: "保留订阅",
            url: "https://keep.example/sub.json",
            rawContent: rawKeep,
            nowMs: 1_000
        )
        let (subDel, _) = try storage.upsertSubscription(
            id: "sub_del",
            name: "待删订阅",
            url: "https://del.example/sub.json",
            rawContent: rawDel,
            nowMs: 1_100
        )
        let siteKeepKey = CmsSite.canonicalScopedKey(rawKey: "keep_s", subscriptionId: subKeep.id)
        let vidA = CmsVideo(id: "vid_a", title: "并发断点片", poster: "https://cdn.example/a.jpg")
        storage.upsertWatchHistory(
            WatchHistoryItem(
                site: siteKeepKey,
                id: vidA.id,
                title: vidA.title,
                poster: vidA.poster,
                line: "默认线路",
                episode: "第1集",
                index: 0,
                position: 60_000,
                duration: 3_600_000,
                updated: 2_000
            )
        )
        _ = storage.toggleFavorite(site: siteKeepKey, video: CmsVideo(id: "fav_old", title: "旧收藏"))

        let initialRemoteJson = """
        {
          "version": 1,
          "exportedAt": 1500,
          "subscriptions": [
            {
              "id": "sub_remote_1",
              "name": "远端订阅",
              "url": "https://rem.example/sub.json",
              "group": "默认分组",
              "format": "JSON",
              "enabled": true,
              "updatedAt": 1500,
              "content": "\(rawRemote.replacingOccurrences(of: "\"", with: "\\\""))"
            }
          ],
          "watchHistory": [
            {
              "site": "rem_s",
              "id": "rem_v1",
              "title": "远端片",
              "poster": "",
              "line": "线路1",
              "episode": "第1集",
              "index": 0,
              "position": 45000,
              "duration": 1800000,
              "updated": 1500
            }
          ],
          "favorites": [
            {
              "site": "rem_s",
              "id": "rem_f1",
              "title": "远端收藏",
              "poster": "",
              "remarks": "",
              "addedAt": 1500
            }
          ],
          "tombstones": {}
        }
        """

        let mockServer = PausableWebDavServer(initialPayload: initialRemoteJson, initialEtag: "\"init-v1\"")
        await mockServer.configurePause(onPutNumber: 1)
        let transport = PausableWebDavTransport(server: mockServer)
        let service = WebDavSyncService(storage: storage, transport: transport)

        var cfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "tester",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try storage.saveWebDavConfig(cfg)

        let syncTask = Task {
            try await service.syncNow()
        }

        await mockServer.waitUntilPutPaused()

        // Mutate storage CONCURRENTLY while PUT #1 is paused in flight:
        // 1) Add new favorite
        let vidDuringPut = CmsVideo(id: "fav_during_put", title: "同步期间新增收藏")
        XCTAssertTrue(storage.toggleFavorite(site: siteKeepKey, video: vidDuringPut))
        // 2) Advance breakpoint from 60s -> 240s
        storage.upsertWatchHistory(
            WatchHistoryItem(
                site: siteKeepKey,
                id: vidA.id,
                title: vidA.title,
                poster: vidA.poster,
                line: "默认线路",
                episode: "第1集",
                index: 0,
                position: 240_000,
                duration: 3_600_000,
                updated: Int64(Date().timeIntervalSince1970 * 1000) + 5_000
            )
        )
        // 3) Delete a local subscription
        storage.removeSubscription(id: subDel.id)

        await mockServer.resumePausedPut()
        let result1 = try await syncTask.value
        XCTAssertGreaterThanOrEqual(result1.favoriteCount, 2)

        // Restart TvStorageManager from disk & keychain and verify EVERY concurrent local mutation + remote merge survived
        let restarted1 = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        XCTAssertTrue(restarted1.favorites().contains(where: { $0.id == "fav_during_put" }))
        XCTAssertTrue(restarted1.favorites().contains(where: { $0.id == "rem_f1" }))
        XCTAssertEqual(restarted1.watchHistory().first(where: { $0.id == "vid_a" })?.position, 240_000)
        XCTAssertTrue(restarted1.watchHistory().contains(where: { $0.id == "rem_v1" }))
        XCTAssertFalse(restarted1.subscriptions().contains(where: { $0.id == subDel.id }), "Deleted subscription must stay deleted")
        XCTAssertTrue(restarted1.subscriptions().contains(where: { $0.url == "https://rem.example/sub.json" }))

        // Remote payload must also have received the follow-up sync with concurrent mutations
        let snapAfter1 = await mockServer.snapshot()
        let remoteText1 = try XCTUnwrap(snapAfter1.payload)
        XCTAssertTrue(remoteText1.contains("fav_during_put"))
        XCTAssertTrue(remoteText1.contains("240000"))
        XCTAssertFalse(remoteText1.contains("https://del.example/sub.json"))

        // Part B: Disable history sync, pause PUT again, mutate disabled history/favorites concurrently -> local mutations MUST survive, remote history stays untouched
        cfg.syncHistory = false
        cfg.syncSubscriptions = true
        try restarted1.saveWebDavConfig(cfg)
        let service2 = WebDavSyncService(storage: restarted1, transport: transport)
        let nextPutNum = snapAfter1.putCount + 1
        await mockServer.configurePause(onPutNumber: nextPutNum)

        let syncTask2 = Task {
            try await service2.syncNow()
        }
        await mockServer.waitUntilPutPaused()

        XCTAssertTrue(restarted1.toggleFavorite(site: siteKeepKey, video: CmsVideo(id: "fav_disabled_cat", title: "关闭历史同步时新增收藏")))
        restarted1.upsertWatchHistory(
            WatchHistoryItem(
                site: siteKeepKey,
                id: vidA.id,
                title: vidA.title,
                poster: vidA.poster,
                line: "默认线路",
                episode: "第1集",
                index: 0,
                position: 360_000,
                duration: 3_600_000,
                updated: Int64(Date().timeIntervalSince1970 * 1000) + 10_000
            )
        )

        await mockServer.resumePausedPut()
        _ = try await syncTask2.value

        let restarted2 = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        XCTAssertTrue(restarted2.favorites().contains(where: { $0.id == "fav_disabled_cat" }))
        XCTAssertEqual(restarted2.watchHistory().first(where: { $0.id == "vid_a" })?.position, 360_000)

        let snapAfter2 = await mockServer.snapshot()
        let remoteText2 = try XCTUnwrap(snapAfter2.payload)
        XCTAssertFalse(remoteText2.contains("fav_disabled_cat"), "Disabled history/favorites category must NOT overwrite remote")
        XCTAssertTrue(remoteText2.contains("rem_f1"), "Remote disabled category must remain intact")
    }

    func testRound2Item1_CachesEvictionUrlOnlyStubSurvivesFailedRefreshAndSync() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2UrlOnlyStub_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainStore()

        let rawStub = #"{"sites":[{"key":"stub_s","name":"缓存前片源","type":1,"api":"https://stub.example/vod"}]}"#
        let initial = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        _ = try initial.upsertSubscription(
            id: "sub_stub_keep",
            name: "我的公开订阅",
            url: "https://stub.example/sub.json",
            rawContent: rawStub,
            group: "常用组",
            isPrivate: false,
            enabled: true,
            nowMs: 5_000
        )

        // Evict tvOS Caches directory -> Keychain Anchor recovers URL-only stub (rawContent == "")
        try FileManager.default.removeItem(at: dir)
        let recovered = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        XCTAssertTrue(recovered.recoveredFromKeychainAnchor)
        XCTAssertTrue(recovered.needsSubscriptionContentRefresh)
        let stubBeforeSync = try XCTUnwrap(recovered.subscriptions().first(where: { $0.id == "sub_stub_keep" }))
        XCTAssertTrue(stubBeforeSync.rawContent.isEmpty)

        // Case A: Startup refresh failed (rawContent still empty) and remote has a different subscription only.
        let remoteOtherOnly = """
        {
          "version": 1,
          "exportedAt": 4000,
          "subscriptions": [
            {
              "id": "sub_other",
              "name": "其他订阅",
              "url": "https://other.example/sub.json",
              "group": "默认分组",
              "format": "JSON",
              "enabled": true,
              "updatedAt": 4000,
              "content": "{\\"sites\\":[{\\"key\\":\\"other_s\\",\\"name\\":\\"其他站\\",\\"type\\":1,\\"api\\":\\"https://other.example/vod\\"}]}"
            }
          ],
          "watchHistory": [],
          "favorites": [],
          "tombstones": {}
        }
        """
        let davCfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "tester",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try recovered.saveWebDavConfig(davCfg)
        let serverA = PausableWebDavServer(initialPayload: remoteOtherOnly, initialEtag: "\"v1\"")
        let serviceA = WebDavSyncService(storage: recovered, transport: PausableWebDavTransport(server: serverA))
        _ = try await serviceA.syncNow()

        let afterFailSync = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let retainedStub = try XCTUnwrap(afterFailSync.subscriptions().first(where: { $0.id == "sub_stub_keep" }))
        XCTAssertEqual(retainedStub.url, "https://stub.example/sub.json")
        XCTAssertEqual(retainedStub.group, "常用组")
        XCTAssertTrue(retainedStub.rawContent.isEmpty)
        XCTAssertTrue(afterFailSync.needsSubscriptionContentRefresh, "Unrefreshed URL-only public stub must keep refresh flag set")
        XCTAssertTrue(afterFailSync.subscriptions().contains(where: { $0.url == "https://other.example/sub.json" }))

        // Case B: Remote now holds a hydrated copy of the same subscription URL -> local stub gets hydrated seamlessly!
        let remoteHydrated = """
        {
          "version": 1,
          "exportedAt": 6000,
          "subscriptions": [
            {
              "id": "sub_remote_hydrated",
              "name": "我的公开订阅",
              "url": "https://stub.example/sub.json",
              "group": "常用组",
              "format": "JSON",
              "enabled": true,
              "updatedAt": 6000,
              "content": "\(rawStub.replacingOccurrences(of: "\"", with: "\\\""))"
            }
          ],
          "watchHistory": [],
          "favorites": [],
          "tombstones": {}
        }
        """
        try afterFailSync.saveWebDavConfig(davCfg)
        let serverB = PausableWebDavServer(initialPayload: remoteHydrated, initialEtag: "\"v2\"")
        let serviceB = WebDavSyncService(storage: afterFailSync, transport: PausableWebDavTransport(server: serverB))
        _ = try await serviceB.syncNow()

        let hydratedSub = try XCTUnwrap(afterFailSync.subscriptions().first(where: { $0.url == "https://stub.example/sub.json" }))
        XCTAssertEqual(hydratedSub.id, "sub_stub_keep", "Hydration must keep original local subscription ID")
        XCTAssertFalse(hydratedSub.rawContent.isEmpty)
        XCTAssertFalse(afterFailSync.needsSubscriptionContentRefresh)
    }

    func testRound2Item1_DualDeviceSimultaneousFirstTimeCreatePreservesBothDevices() async throws {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoR2DevA_\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoR2DevB_\(UUID().uuidString)", isDirectory: true)
        let dirC = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoR2DevC_\(UUID().uuidString)", isDirectory: true)
        let dirD = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoR2DevD_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: dirC)
            try? FileManager.default.removeItem(at: dirD)
        }

        let storageA = TvStorageManager(cachesDirectory: dirA, keychain: InMemoryKeychainStore())
        let storageB = TvStorageManager(cachesDirectory: dirB, keychain: InMemoryKeychainStore())
        let storageC = TvStorageManager(cachesDirectory: dirC, keychain: InMemoryKeychainStore())
        let storageD = TvStorageManager(cachesDirectory: dirD, keychain: InMemoryKeychainStore())

        let rawA = #"{"sites":[{"key":"dev_a","name":"设备A站","type":1,"api":"https://deva.example/vod"}]}"#
        let rawB = #"{"sites":[{"key":"dev_b","name":"设备B站","type":1,"api":"https://devb.example/vod"}]}"#
        let rawC = #"{"sites":[{"key":"dev_c","name":"设备C站","type":1,"api":"https://devc.example/vod"}]}"#
        let rawD = #"{"sites":[{"key":"dev_d","name":"设备D站","type":1,"api":"https://devd.example/vod"}]}"#

        _ = try storageA.upsertSubscription(id: "sub_a", name: "A订阅", url: "https://deva.example/sub.json", rawContent: rawA, nowMs: 1_000)
        _ = storageA.toggleFavorite(site: "sub::sub_a::dev_a", video: CmsVideo(id: "fav_a", title: "A片"))
        _ = try storageB.upsertSubscription(id: "sub_b", name: "B订阅", url: "https://devb.example/sub.json", rawContent: rawB, nowMs: 2_000)
        _ = storageB.toggleFavorite(site: "sub::sub_b::dev_b", video: CmsVideo(id: "fav_b", title: "B片"))
        _ = try storageC.upsertSubscription(id: "sub_c", name: "C订阅", url: "https://devc.example/sub.json", rawContent: rawC, nowMs: 3_000)
        _ = storageC.toggleFavorite(site: "sub::sub_c::dev_c", video: CmsVideo(id: "fav_c", title: "C片"))
        _ = try storageD.upsertSubscription(id: "sub_d", name: "D订阅", url: "https://devd.example/sub.json", rawContent: rawD, nowMs: 4_000)
        _ = storageD.toggleFavorite(site: "sub::sub_d::dev_d", video: CmsVideo(id: "fav_d", title: "D片"))

        let davCfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "tester",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try storageA.saveWebDavConfig(davCfg)
        try storageB.saveWebDavConfig(davCfg)
        try storageC.saveWebDavConfig(davCfg)
        try storageD.saveWebDavConfig(davCfg)

        // Subtest 1: Empty remote; Device A creates first, Device B gets 412 on If-None-Match: * and merges BOTH
        let server1 = PausableWebDavServer(initialPayload: nil, initialEtag: nil)
        let serviceA = WebDavSyncService(storage: storageA, transport: PausableWebDavTransport(server: server1))
        _ = try await serviceA.syncNow()
        let createdByA = try XCTUnwrap(await server1.snapshot().payload)

        // Simulate Device B having started while remote was 404, and A committing right before B's If-None-Match: * PUT
        let serverRace412 = PausableWebDavServer(initialPayload: nil, initialEtag: nil)
        await serverRace412.configureIfNoneMatchRejection(status: nil, concurrentRemote: (createdByA, "\"etag-a\""))
        let serviceB = WebDavSyncService(storage: storageB, transport: PausableWebDavTransport(server: serverRace412))
        _ = try await serviceB.syncNow()
        let snap412 = await serverRace412.snapshot()
        XCTAssertEqual(snap412.unconditionalPutCount, 0, "First-time 412 race must NEVER issue unconditional overwrite")
        let merged412 = try XCTUnwrap(snap412.payload)
        XCTAssertTrue(merged412.contains("fav_a") && merged412.contains("fav_b"))
        XCTAssertTrue(storageB.favorites().contains(where: { $0.id == "fav_a" }))
        XCTAssertTrue(storageB.favorites().contains(where: { $0.id == "fav_b" }))

        // Subtest 2: Server rejects If-None-Match: * with HTTP 400 while Device A concurrently created the file ->
        // Device C probes via GET, discovers A's data, merges A + C, and NEVER blindly overwrites A!
        let serverRace400 = PausableWebDavServer(initialPayload: nil, initialEtag: nil)
        await serverRace400.configureIfNoneMatchRejection(status: 400, concurrentRemote: (createdByA, "\"etag-a-400\""))
        let serviceC = WebDavSyncService(storage: storageC, transport: PausableWebDavTransport(server: serverRace400))
        _ = try await serviceC.syncNow()
        let snap400 = await serverRace400.snapshot()
        XCTAssertEqual(snap400.unconditionalPutCount, 0, "400 on If-None-Match must probe GET and merge conditionally when remote exists")
        let merged400 = try XCTUnwrap(snap400.payload)
        XCTAssertTrue(merged400.contains("fav_a") && merged400.contains("fav_c"))
        XCTAssertTrue(storageC.favorites().contains(where: { $0.id == "fav_a" }))
        XCTAssertTrue(storageC.favorites().contains(where: { $0.id == "fav_c" }))

        // Subtest 3: HTTP 500 on If-None-Match: * when remote is still 404 must fail safely without blind unconditional PUT
        let serverRace500 = PausableWebDavServer(initialPayload: nil, initialEtag: nil)
        await serverRace500.configureIfNoneMatchRejection(status: 500, concurrentRemote: nil)
        let serviceD = WebDavSyncService(storage: storageD, transport: PausableWebDavTransport(server: serverRace500))
        do {
            _ = try await serviceD.syncNow()
            XCTFail("HTTP 500 on first-time create with 404 probe must fail safely instead of issuing unconditional PUT")
        } catch {
            // Expected safe abort
        }
        let snap500 = await serverRace500.snapshot()
        XCTAssertEqual(snap500.unconditionalPutCount, 0)
        XCTAssertTrue(storageD.favorites().contains(where: { $0.id == "fav_d" }), "Local data must remain preserved on 500 failure")
    }

    // MARK: - Item 2: Private Parent Overrides Child Flags & Hides History/Favorites/Backdrop

    func testRound2Item2_PrivateParentOverridesChildPublicFlagsAndHidesCardsAndBackdrop() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2PrivateBoundary_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainStore()

        // 1) Child VOD & Live explicitly declaring isPrivate=false inside a private parent MUST still be private!
        let trickyPrivateJson = """
        {
          "sites": [
            {
              "key": "child_vod_escape",
              "name": "企图逃逸的点播站",
              "type": 1,
              "api": "https://priv-escape.invalid/vod",
              "isPrivate": false,
              "hidden": false
            }
          ],
          "lives": [
            {
              "name": "企图逃逸的直播源",
              "url": "https://priv-escape.invalid/live.m3u",
              "isPrivate": false,
              "hidden": false
            }
          ]
        }
        """
        let parsedPriv = CmsParser.parseConfig(
            raw: trickyPrivateJson,
            groupLabel: "普通分组",
            isPrivate: true
        )
        XCTAssertEqual(parsedPriv.sites.count, 1)
        XCTAssertTrue(parsedPriv.sites[0].isPrivate, "Private parent must override child isPrivate:false on VOD site")
        XCTAssertTrue(parsedPriv.sites[0].isEffectivelyPrivate)
        XCTAssertTrue(parsedPriv.publicAvailableSites.isEmpty)
        XCTAssertEqual(parsedPriv.lives.count, 1)
        XCTAssertTrue(parsedPriv.lives[0].isPrivate, "Private parent must override child isPrivate:false on Live source")
        XCTAssertTrue(parsedPriv.lives[0].isEffectivelyPrivate)
        XCTAssertTrue(parsedPriv.publicSupportedLives.isEmpty)

        // 2) Watched & favorited public site switched to private + ambientPosterSync ON -> cold start hides cards & backdrop
        let storage1 = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let alphaJson = #"{"sites":[{"key":"alpha","name":"阿尔法站","type":1,"api":"https://alpha.example/vod"}],"lives":[{"name":"阿尔法直播","url":"https://alpha.example/live.m3u","isPrivate":false}]}"#
        let betaJson = #"{"sites":[{"key":"beta","name":"贝塔公开站","type":1,"api":"https://beta.example/vod"}]}"#

        let (subAlpha, _) = try storage1.upsertSubscription(
            id: "sub_alpha",
            name: "阿尔法订阅",
            url: "https://alpha.example/sub.json",
            rawContent: alphaJson,
            isPrivate: false,
            enabled: true,
            nowMs: 1_000
        )
        let (subBeta, _) = try storage1.upsertSubscription(
            id: "sub_beta",
            name: "贝塔订阅",
            url: "https://beta.example/sub.json",
            rawContent: betaJson,
            isPrivate: false,
            enabled: true,
            nowMs: 1_100
        )

        let alphaSiteKey = CmsSite.canonicalScopedKey(rawKey: "alpha", subscriptionId: subAlpha.id)
        let betaSiteKey = CmsSite.canonicalScopedKey(rawKey: "beta", subscriptionId: subBeta.id)
        let alphaPoster = "https://private-poster.invalid/alpha_secret.jpg"
        let betaPoster = "https://public-poster.invalid/beta_ok.jpg"

        storage1.upsertWatchHistory(
            WatchHistoryItem(
                site: betaSiteKey,
                id: "100",
                title: "公开影片",
                poster: betaPoster,
                line: "线1",
                episode: "第1集",
                index: 0,
                position: 30_000,
                duration: 3_000_000,
                updated: 2_000
            )
        )
        storage1.upsertWatchHistory(
            WatchHistoryItem(
                site: alphaSiteKey,
                id: "200",
                title: "后来变私密的影片",
                poster: alphaPoster,
                line: "线1",
                episode: "第2集",
                index: 1,
                position: 90_000,
                duration: 3_000_000,
                updated: 5_000
            )
        )
        _ = storage1.toggleFavorite(site: alphaSiteKey, video: CmsVideo(id: "200", title: "后来变私密的影片", poster: alphaPoster))
        _ = storage1.toggleFavorite(site: betaSiteKey, video: CmsVideo(id: "100", title: "公开影片", poster: betaPoster))
        storage1.updatePreferences { $0.ambientPosterSync = true }

        // Mark subAlpha as private and cold-start fresh TvStorageManager
        var subs = storage1.subscriptions()
        if let idx = subs.firstIndex(where: { $0.id == "sub_alpha" }) {
            subs[idx].isPrivate = true
        }
        storage1.saveSubscriptions(subs)

        let coldStorage = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let coldConfig = coldStorage.mergedConfig()
        XCTAssertEqual(coldConfig.publicAvailableSites.map(\.rawKey), ["beta"])
        XCTAssertTrue(coldConfig.publicSupportedLives.isEmpty)

        let pubHistory = MediaEntryResolver.publicVisibleWatchHistory(coldStorage.watchHistory(), in: coldConfig)
        let pubFavs = MediaEntryResolver.publicVisibleFavorites(coldStorage.favorites(), in: coldConfig)
        XCTAssertEqual(pubHistory.map(\.title), ["公开影片"])
        XCTAssertEqual(pubFavs.map(\.title), ["公开影片"])

        let backdrop1 = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: coldStorage.preferences().ambientPosterSync,
            publicWatchHistory: pubHistory,
            discoverVideos: [],
            config: coldConfig
        )
        XCTAssertEqual(backdrop1, betaPoster, "Backdrop must fall back to public poster and never request private poster")

        // Now mark beta private too -> cold start must have ZERO public cards AND empty backdrop (no poster request!)
        var subsAllPriv = coldStorage.subscriptions()
        for i in subsAllPriv.indices { subsAllPriv[i].isPrivate = true }
        coldStorage.saveSubscriptions(subsAllPriv)

        let coldStorage2 = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let coldConfig2 = coldStorage2.mergedConfig()
        let pubHistory2 = MediaEntryResolver.publicVisibleWatchHistory(coldStorage2.watchHistory(), in: coldConfig2)
        let pubFavs2 = MediaEntryResolver.publicVisibleFavorites(coldStorage2.favorites(), in: coldConfig2)
        XCTAssertTrue(pubHistory2.isEmpty)
        XCTAssertTrue(pubFavs2.isEmpty)
        let backdrop2 = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: true,
            publicWatchHistory: pubHistory2,
            discoverVideos: [],
            config: coldConfig2
        )
        XCTAssertEqual(backdrop2, "", "When only private history exists, backdrop URL must be empty so no poster is fetched")

        // Original private records remain preserved in storage
        XCTAssertEqual(coldStorage2.watchHistory().count, 2)
        XCTAssertEqual(coldStorage2.favorites().count, 2)
    }

    // MARK: - Item 3: Duplicate-Named Sites, Reorder/Disable Stability, Strict Detail ID Match

    func testRound2Item3_DuplicateSiteNamesSurviveDisableRestoreReorderRestartAndRejectAmbiguousLegacy() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2DupSites_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainStore()

        let rawSubA = #"{"sites":[{"key":"cms","name":"同名字典站A","type":1,"api":"https://dup-a.example/vod"}]}"#
        let rawSubB = #"{"sites":[{"key":"cms","name":"同名字典站B","type":1,"api":"https://dup-b.example/vod"}]}"#
        let rawSubUnique = #"{"sites":[{"key":"solo_legacy","name":"唯一旧站","type":1,"api":"https://solo.example/vod"}]}"#

        let requestedHosts = R2LockedBox<[String]>([])
        defer { R2StubURLProtocol.uninstall() }
        R2StubURLProtocol.install { request in
            let url = request.url ?? URL(string: "https://dup-a.example/vod")!
            let host = url.host ?? ""
            requestedHosts.withLock { $0.append(host) }
            switch host {
            case "dup-a.example":
                let json = #"{"list":[{"vod_id":"42","vod_name":"A站42·星际穿越","vod_pic":"https://cdn.example/a42.jpg","vod_play_from":"A线","vod_play_url":"正片$https://cdn.example/a42.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            case "dup-b.example":
                let json = #"{"list":[{"vod_id":"42","vod_name":"B站42·盗梦空间","vod_pic":"https://cdn.example/b42.jpg","vod_play_from":"B线","vod_play_url":"正片$https://cdn.example/b42.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            case "solo.example":
                let json = #"{"list":[{"vod_id":"7","vod_name":"唯一旧片7","vod_pic":"","vod_play_from":"S线","vod_play_url":"正片$https://cdn.example/s7.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.protocolClasses = [R2StubURLProtocol.self]
        let client = CmsClient(session: URLSession(configuration: sessionCfg))

        let storage = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        _ = try storage.upsertSubscription(id: "sub_a", name: "订阅A", url: "https://dup-a.example/sub.json", rawContent: rawSubA, nowMs: 1_000)
        _ = try storage.upsertSubscription(id: "sub_b", name: "订阅B", url: "https://dup-b.example/sub.json", rawContent: rawSubB, nowMs: 1_100)
        _ = try storage.upsertSubscription(id: "sub_solo", name: "订阅Solo", url: "https://solo.example/sub.json", rawContent: rawSubUnique, nowMs: 1_200)

        let cfg1 = storage.mergedConfig()
        let siteA = try XCTUnwrap(cfg1.publicAvailableSites.first(where: { $0.subscriptionId == "sub_a" }))
        let siteB = try XCTUnwrap(cfg1.publicAvailableSites.first(where: { $0.subscriptionId == "sub_b" }))
        XCTAssertEqual(siteA.rawKey, "cms")
        XCTAssertEqual(siteB.rawKey, "cms")
        XCTAssertEqual(siteA.key, "sub::sub_a::cms")
        XCTAssertEqual(siteB.key, "sub::sub_b::cms")

        // Watch & favorite video 42 on BOTH duplicate-named sites
        storage.upsertWatchHistory(
            WatchHistoryItem(site: siteA.key, id: "42", title: "A站42·星际穿越", poster: "", line: "A线", episode: "正片", index: 0, position: 90_000, duration: 5_000_000, updated: 2_000)
        )
        storage.upsertWatchHistory(
            WatchHistoryItem(site: siteB.key, id: "42", title: "B站42·盗梦空间", poster: "", line: "B线", episode: "正片", index: 0, position: 180_000, duration: 5_000_000, updated: 3_000)
        )
        _ = storage.toggleFavorite(site: siteA.key, video: CmsVideo(id: "42", title: "A站42·星际穿越"))
        _ = storage.toggleFavorite(site: siteB.key, video: CmsVideo(id: "42", title: "B站42·盗梦空间"))

        // 1) Disable sub_a -> B's canonical key MUST NOT change; A's record MUST report unavailable without querying B!
        var subs = storage.subscriptions()
        subs[subs.firstIndex(where: { $0.id == "sub_a" })!].enabled = false
        storage.saveSubscriptions(subs)
        let cfgDisabledA = storage.mergedConfig()
        XCTAssertEqual(cfgDisabledA.publicAvailableSites.first(where: { $0.subscriptionId == "sub_b" })?.key, "sub::sub_b::cms")

        let histA = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == siteA.key }))
        let histB = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == siteB.key }))
        let favA = try XCTUnwrap(storage.favorites().first(where: { $0.site == siteA.key }))
        let favB = try XCTUnwrap(storage.favorites().first(where: { $0.site == siteB.key }))

        requestedHosts.withLock { $0.removeAll() }
        let resDisabledA = try await MediaEntryResolver.resolveWatchHistoryEntry(histA, config: cfgDisabledA, cmsClient: client)
        guard case .sourceUnavailable = resDisabledA else {
            return XCTFail("Expected A's history to be unavailable when sub_a is disabled")
        }
        XCTAssertTrue(requestedHosts.withLock { $0.isEmpty }, "Must NEVER query sub_b for disabled sub_a record")

        let resActiveB = try await MediaEntryResolver.resolveWatchHistoryEntry(histB, config: cfgDisabledA, cmsClient: client)
        guard case .ready(let bOut, let bVid, let bResume) = resActiveB else {
            return XCTFail("Expected B's history to stay playable when sub_a is disabled")
        }
        XCTAssertEqual(bOut.key, "sub::sub_b::cms")
        XCTAssertEqual(bVid.title, "B站42·盗梦空间")
        XCTAssertEqual(bResume?.resumePosition, 180_000)

        // Legacy bare key "cms" is AMBIGUOUS across sub_a & sub_b even while sub_a is disabled -> MUST NOT guess B!
        requestedHosts.withLock { $0.removeAll() }
        let ambiguousLegacy = WatchHistoryItem(site: "cms", id: "42", title: "旧版重名记录", poster: "", line: "", episode: "", index: 0, position: 50_000, duration: 1_000_000, updated: 1_500)
        let resAmbiguous = try await MediaEntryResolver.resolveWatchHistoryEntry(ambiguousLegacy, config: cfgDisabledA, cmsClient: client)
        guard case .sourceUnavailable(_, let ambigReason) = resAmbiguous else {
            return XCTFail("Ambiguous legacy bare key 'cms' must NOT auto-guess subscription B")
        }
        XCTAssertTrue(ambigReason.contains("同名"))
        XCTAssertTrue(requestedHosts.withLock { $0.isEmpty })

        // 2) Restore sub_a, REVERSE subscription order [sub_b, sub_a, sub_solo], and restart TvStorageManager!
        let subObjA = subs.first(where: { $0.id == "sub_a" })!
        var restoredSubA = subObjA
        restoredSubA.enabled = true
        let subObjB = subs.first(where: { $0.id == "sub_b" })!
        let subObjSolo = subs.first(where: { $0.id == "sub_solo" })!
        storage.saveSubscriptions([subObjB, restoredSubA, subObjSolo])

        let restarted = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let restartedCfg = restarted.mergedConfig()

        let resA2 = try await MediaEntryResolver.resolveFavoriteEntry(favA, config: restartedCfg, watchHistory: restarted.watchHistory(), cmsClient: client)
        guard case .ready(let siteA2, let vidA2, let resumeA2) = resA2 else {
            return XCTFail("Expected A favorite to point to A after reorder + restart")
        }
        XCTAssertEqual(siteA2.subscriptionId, "sub_a")
        XCTAssertEqual(vidA2.title, "A站42·星际穿越")
        XCTAssertEqual(resumeA2?.resumePosition, 90_000)

        let resB2 = try await MediaEntryResolver.resolveFavoriteEntry(favB, config: restartedCfg, watchHistory: restarted.watchHistory(), cmsClient: client)
        guard case .ready(let siteB2, let vidB2, let resumeB2) = resB2 else {
            return XCTFail("Expected B favorite to point to B after reorder + restart")
        }
        XCTAssertEqual(siteB2.subscriptionId, "sub_b")
        XCTAssertEqual(vidB2.title, "B站42·盗梦空间")
        XCTAssertEqual(resumeB2?.resumePosition, 180_000)

        // 3) Legacy v0.1.1 suffixed key "cms_sub_b" & unambiguous legacy bare key "solo_legacy" remain compatible
        let legacySuffixed = WatchHistoryItem(site: "cms_sub_b", id: "42", title: "旧版后缀记录", poster: "", line: "", episode: "", index: 0, position: 70_000, duration: 1_000_000, updated: 1_600)
        let resLegacyB = try await MediaEntryResolver.resolveWatchHistoryEntry(legacySuffixed, config: restartedCfg, cmsClient: client)
        guard case .ready(let legacyBOut, let legacyBVid, _) = resLegacyB else {
            return XCTFail("Expected legacy suffixed key cms_sub_b to resolve to sub_b")
        }
        XCTAssertEqual(legacyBOut.subscriptionId, "sub_b")
        XCTAssertEqual(legacyBVid.title, "B站42·盗梦空间")

        let legacySolo = WatchHistoryItem(site: "solo_legacy", id: "7", title: "唯一旧片7", poster: "", line: "", episode: "", index: 0, position: 15_000, duration: 1_000_000, updated: 1_700)
        let resLegacySolo = try await MediaEntryResolver.resolveWatchHistoryEntry(legacySolo, config: restartedCfg, cmsClient: client)
        guard case .ready(_, let soloVid, _) = resLegacySolo else {
            return XCTFail("Expected unambiguous legacy bare key solo_legacy to resolve")
        }
        XCTAssertEqual(soloVid.title, "唯一旧片7")
    }

    func testRound2Item3_DetailIdMismatchThrowsUnavailableAndPreservesOriginalBreakpoint() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2IdMismatch_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        defer { R2StubURLProtocol.uninstall() }
        R2StubURLProtocol.install { request in
            let url = request.url ?? URL(string: "https://mismatch.example/vod")!
            // Requested ids=42, but server erroneously returns only vod_id=43
            let wrongJson = #"{"list":[{"vod_id":"43","vod_name":"错位影片43","vod_play_from":"默认","vod_play_url":"正片$https://cdn.example/43.m3u8"}]}"#
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(wrongJson.utf8))
        }

        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.protocolClasses = [R2StubURLProtocol.self]
        let client = CmsClient(session: URLSession(configuration: sessionCfg))

        let storage = TvStorageManager(cachesDirectory: dir, keychain: InMemoryKeychainStore())
        let raw = #"{"sites":[{"key":"mm_site","name":"错位测试站","type":1,"api":"https://mismatch.example/vod"}]}"#
        _ = try storage.upsertSubscription(id: "sub_mm", name: "错位测试", url: "https://mismatch.example/sub.json", rawContent: raw)
        let cfg = storage.mergedConfig()
        let site = try XCTUnwrap(cfg.publicAvailableSites.first)

        let savedHist = WatchHistoryItem(
            site: site.key,
            id: "42",
            title: "原片42",
            poster: "",
            line: "默认",
            episode: "第1集",
            index: 0,
            position: 120_000,
            duration: 3_600_000,
            updated: 9_000
        )
        storage.upsertWatchHistory(savedHist)

        do {
            _ = try await MediaEntryResolver.resolveWatchHistoryEntry(savedHist, config: cfg, cmsClient: client)
            XCTFail("Expected detail ID mismatch (requested 42, returned 43) to throw unavailable error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("原片") || error.localizedDescription.contains("42"), "Unexpected error: \(error.localizedDescription)")
        }

        // Breakpoint for original movie 42 MUST remain untouched!
        let preserved = try XCTUnwrap(storage.watchHistory().first(where: { $0.id == "42" && $0.site == site.key }))
        XCTAssertEqual(preserved.position, 120_000)
        XCTAssertEqual(preserved.title, "原片42")
    }

    // MARK: - Item 4: Per-Session Proxy Resource Release Under Tight Memory Budget

    @MainActor
    func testRound2Item4_PerSessionProxyResourceReleaseUnderTightBudgetAcrossSwitchesAndExits() async throws {
        let upstream = FaultInjectingRangeServer(payloadSize: 262_144, chunkSize: 65_536)
        let upPort = try await upstream.start()
        defer { upstream.stop() }

        // Tight budget: ONLY 2 chunks (128 KiB) total across the whole shared proxy!
        let rangeProxy = NetdiskRangeProxyServer(
            workers: 2,
            chunkSize: 65_536,
            memoryLimit: 131_072
        )
        defer { rangeProxy.stop() }
        let headerProxy = LocalHeaderProxyServer()
        defer { headerProxy.stop() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoR2ProxyRelease_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = TvStorageManager(cachesDirectory: dir, keychain: InMemoryKeychainStore())
        storage.updatePreferences { $0.playerKernel = "range_proxy" }

        let client = CmsClient()
        let site = CmsSite(key: "sub::s1::direct", name: "直连测试站", type: 1, api: "http://127.0.0.1:\(upPort)/vod")

        func makeMovie(id: String, title: String) -> CmsVideo {
            CmsVideo(
                id: id,
                title: title,
                lines: [
                    CmsLine(
                        name: "直连4K",
                        episodes: [
                            CmsEpisode(name: "第1集", url: "http://127.0.0.1:\(upPort)/\(id)_ep1.mp4", headers: ["X-Test": "1"]),
                            CmsEpisode(name: "第2集", url: "http://127.0.0.1:\(upPort)/\(id)_ep2.mp4", headers: ["X-Test": "1"]),
                        ]
                    )
                ]
            )
        }

        let resolvedBox = R2LockedBox<[ResolvedPlayback]>([])
        let makeCoordinator: (CmsVideo, R2MockPlaybackEngine) -> PlaybackSessionCoordinator = { video, engine in
            PlaybackSessionCoordinator(
                initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
                engine: engine,
                resolver: { target in
                    let line = target.currentLine!
                    let ep = target.currentEpisode!
                    let resolved = try await client.resolvePlayback(
                        site: target.site,
                        lineName: line.name,
                        episode: ep,
                        parses: [],
                        proxyServer: headerProxy,
                        storage: storage,
                        rangeProxyServer: rangeProxy,
                        isLiveStream: false
                    )
                    resolvedBox.withLock { $0.append(resolved) }
                    return resolved
                },
                progressRecorder: { _, _, _ in },
                resourceReleaser: { resolved in
                    if let rid = resolved.rangeProxyResourceId {
                        await rangeProxy.revokeResource(rid)
                    }
                    if let hid = resolved.headerProxySessionId {
                        headerProxy.revokeSession(hid)
                    }
                }
            )
        }

        // Play Movie 1 EP 1 -> fetch initial bytes (fills prefetch window) -> switch to EP 2 -> exit
        let engine1 = R2MockPlaybackEngine()
        let coord1 = makeCoordinator(makeMovie(id: "m1", title: "影片1"), engine1)
        coord1.startInitialLoad()
        try await waitUntil { engine1.loads.count == 1 }

        let res1 = try XCTUnwrap(resolvedBox.withLock { $0.last })
        let rid1 = try XCTUnwrap(res1.rangeProxyResourceId, "CmsClient range_proxy must populate rangeProxyResourceId")
        XCTAssertTrue(rangeProxy.hasActiveResource(rid1))

        let firstChunk1 = try await fetchUrlRange(res1.playableUrl, range: "bytes=0-65535")
        XCTAssertEqual(firstChunk1.status, 206)
        XCTAssertEqual(firstChunk1.body, upstream.payload.subdata(in: 0..<65_536))

        // Switch episode -> old resource rid1 MUST be released automatically
        coord1.switchToEpisode(lineIndex: 0, episodeIndex: 1, seekMs: 0)
        try await waitUntil { engine1.loads.count == 2 }
        await coord1.waitForPendingResourceReleases()
        XCTAssertFalse(rangeProxy.hasActiveResource(rid1), "Switching episode must release previous session's proxy resource")
        let revokedResp = try await fetchUrlRange(res1.playableUrl, range: "bytes=0-1023")
        XCTAssertEqual(revokedResp.status, 404, "Revoked episode resource must reject further requests")

        let res2 = try XCTUnwrap(resolvedBox.withLock { $0.last })
        let rid2 = try XCTUnwrap(res2.rangeProxyResourceId)
        XCTAssertTrue(rangeProxy.hasActiveResource(rid2))
        let firstChunk2 = try await fetchUrlRange(res2.playableUrl, range: "bytes=0-65535")
        XCTAssertEqual(firstChunk2.status, 206)
        XCTAssertEqual(firstChunk2.body, upstream.payload.subdata(in: 0..<65_536))

        // Normal player exit -> MUST release rid2 and free 100% of shared memory budget
        coord1.teardownAndPersist()
        await coord1.waitForPendingResourceReleases()
        XCTAssertFalse(rangeProxy.hasActiveResource(rid2))
        XCTAssertEqual(rangeProxy.activeResourceCount(), 0)
        let metricsAfterExit1 = await rangeProxy.metrics()
        XCTAssertEqual(metricsAfterExit1.currentBufferedBytes, 0, "Shared memory pool must drop to 0 after player exit")

        // Play Movie 2 and Movie 3 back-to-back under the exact same tight 128 KiB budget
        for movieNum in 2...3 {
            let eng = R2MockPlaybackEngine()
            let coord = makeCoordinator(makeMovie(id: "m\(movieNum)", title: "影片\(movieNum)"), eng)
            coord.startInitialLoad()
            try await waitUntil { eng.loads.count == 1 }
            let resolved = try XCTUnwrap(resolvedBox.withLock { $0.last })
            let resp = try await fetchUrlRange(resolved.playableUrl, range: "bytes=0-65535")
            XCTAssertEqual(resp.status, 206, "Movie \(movieNum) must start cleanly under tight budget")
            XCTAssertEqual(resp.body, upstream.payload.subdata(in: 0..<65_536))
            coord.teardownAndPersist()
            await coord.waitForPendingResourceReleases()
        }
        XCTAssertEqual(rangeProxy.activeResourceCount(), 0)
        let metricsFinal = await rangeProxy.metrics()
        XCTAssertEqual(metricsFinal.currentBufferedBytes, 0)

        // Per-session isolation: exiting Session A must NOT disturb concurrently active Session B!
        let engA = R2MockPlaybackEngine()
        let engB = R2MockPlaybackEngine()
        let coordA = makeCoordinator(makeMovie(id: "iso_a", title: "隔离A"), engA)
        let coordB = makeCoordinator(makeMovie(id: "iso_b", title: "隔离B"), engB)
        coordA.startInitialLoad()
        try await waitUntil { engA.loads.count == 1 }
        let resA = try XCTUnwrap(resolvedBox.withLock { $0.last })
        coordB.startInitialLoad()
        try await waitUntil { engB.loads.count == 1 }
        let resB = try XCTUnwrap(resolvedBox.withLock { $0.last })

        coordA.teardownAndPersist()
        await coordA.waitForPendingResourceReleases()

        XCTAssertFalse(rangeProxy.hasActiveResource(try XCTUnwrap(resA.rangeProxyResourceId)))
        XCTAssertTrue(rangeProxy.hasActiveResource(try XCTUnwrap(resB.rangeProxyResourceId)), "Closing session A must NOT revoke session B")
        let bResp = try await fetchUrlRange(resB.playableUrl, range: "bytes=65536-131071")
        XCTAssertEqual(bResp.status, 206)
        XCTAssertEqual(bResp.body, upstream.payload.subdata(in: 65_536..<131_072))

        coordB.teardownAndPersist()
        await coordB.waitForPendingResourceReleases()
        XCTAssertEqual(rangeProxy.activeResourceCount(), 0)

        // Also verify LocalHeaderProxyServer session release for custom-header HLS episodes
        let hlsMovie = CmsVideo(
            id: "hls_1",
            title: "HLS片",
            lines: [
                CmsLine(
                    name: "HLS线",
                    episodes: [
                        CmsEpisode(name: "正片", url: "http://127.0.0.1:\(upPort)/stream.m3u8", headers: ["Referer": "http://127.0.0.1:\(upPort)/"])
                    ]
                )
            ]
        )
        let engHls = R2MockPlaybackEngine()
        let coordHls = makeCoordinator(hlsMovie, engHls)
        coordHls.startInitialLoad()
        try await waitUntil { engHls.loads.count == 1 }
        let resHls = try XCTUnwrap(resolvedBox.withLock { $0.last })
        let hlsSid = try XCTUnwrap(resHls.headerProxySessionId, "Custom-header HLS must populate headerProxySessionId")
        XCTAssertTrue(headerProxy.hasActiveSession(hlsSid))
        coordHls.teardownAndPersist()
        await coordHls.waitForPendingResourceReleases()
        XCTAssertFalse(headerProxy.hasActiveSession(hlsSid), "Player exit must release LocalHeaderProxyServer session")
        XCTAssertEqual(headerProxy.activeSessionCount(), 0)
    }

    // MARK: - Item 5: 206 Byte Integrity & No Double HTTP Headers After Body Starts

    func testRound2Item5_RangeProxyValidates206IntegrityAndNeverEmitsDoubleHeaders() async throws {
        let chunkSize = 65_536
        let upstream = FaultInjectingRangeServer(payloadSize: 262_144, chunkSize: chunkSize)
        let upPort = try await upstream.start()
        defer { upstream.stop() }

        let proxy = NetdiskRangeProxyServer(workers: 2, chunkSize: chunkSize, memoryLimit: chunkSize * 4)
        defer { proxy.stop() }

        let mediaUrl = URL(string: "http://127.0.0.1:\(upPort)/integrity.mp4")!
        let policy = NetdiskHeaderPolicy(originUrl: mediaUrl, allowInsecureLoopbackCredentials: true)

        // 1) Normal valid 206 -> byte-for-byte match across 2 chunks
        upstream.setMode(.valid206)
        let (resValid, urlValid) = try await proxy.registerStream(url: mediaUrl, policy: policy)
        let rawValid = try await rawLoopbackHttpRequest(url: urlValid, range: "bytes=0-131071")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawValid), 1)
        let parsedValid = try parseRawHttpResponse(rawValid)
        XCTAssertEqual(parsedValid.status, 206)
        XCTAssertEqual(parsedValid.body, upstream.payload.subdata(in: 0..<131_072))
        await proxy.revokeResource(resValid)

        // 2a) Short/truncated 206 body on chunk 0 -> returns clean 502, MUST NOT cache truncated bytes; recovery succeeds byte-for-byte
        upstream.setMode(.shortBodyOnChunk(targetChunk: 0, truncatedBytes: 12_345))
        let (resShort0, urlShort0) = try await proxy.registerStream(url: mediaUrl, policy: policy)
        let rawShort0 = try await rawLoopbackHttpRequest(url: urlShort0, range: "bytes=0-65535")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawShort0), 1)
        XCTAssertEqual(try parseRawHttpResponse(rawShort0).status, 502)

        upstream.setMode(.valid206)
        let rawShort0Recovered = try await rawLoopbackHttpRequest(url: urlShort0, range: "bytes=0-65535")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawShort0Recovered), 1)
        let parsedShort0Rec = try parseRawHttpResponse(rawShort0Recovered)
        XCTAssertEqual(parsedShort0Rec.status, 206)
        XCTAssertEqual(parsedShort0Rec.body, upstream.payload.subdata(in: 0..<65_536))
        await proxy.revokeResource(resShort0)

        // 2b) Short/truncated 206 body on chunk 1 AFTER chunk 0 already streamed ->
        // MUST close socket cleanly with EXACTLY ONE HTTP header block (NO embedded second 502/206/200 header!)
        upstream.setMode(.shortBodyOnChunk(targetChunk: 1, truncatedBytes: 8_192))
        let (resShort1, urlShort1) = try await proxy.registerStream(url: mediaUrl, policy: policy)
        let rawShort1 = try await rawLoopbackHttpRequest(url: urlShort1, range: "bytes=0-131071")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawShort1), 1, "Must NEVER emit a second HTTP response header after body started")
        let parsedShort1 = try parseRawHttpResponse(rawShort1)
        XCTAssertEqual(parsedShort1.status, 206)
        XCTAssertLessThan(parsedShort1.body.count, 131_072)
        XCTAssertEqual(parsedShort1.body.prefix(65_536), upstream.payload.subdata(in: 0..<65_536))

        upstream.setMode(.valid206)
        let rawShort1Recovered = try await rawLoopbackHttpRequest(url: urlShort1, range: "bytes=65536-131071")
        let parsedShort1Rec = try parseRawHttpResponse(rawShort1Recovered)
        XCTAssertEqual(parsedShort1Rec.status, 206)
        XCTAssertEqual(parsedShort1Rec.body, upstream.payload.subdata(in: 65_536..<131_072))
        await proxy.revokeResource(resShort1)

        // 3) Wrong Content-Range interval on chunk 1 after chunk 0 streamed -> single HTTP header, abort, then clean recovery
        upstream.setMode(.wrongContentRangeOnChunk(targetChunk: 1))
        let (resWrongCR, urlWrongCR) = try await proxy.registerStream(url: mediaUrl, policy: policy)
        let rawWrongCR = try await rawLoopbackHttpRequest(url: urlWrongCR, range: "bytes=0-131071")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawWrongCR), 1, "Wrong Content-Range mid-stream must abort cleanly with single HTTP header")
        let parsedWrongCR = try parseRawHttpResponse(rawWrongCR)
        XCTAssertEqual(parsedWrongCR.status, 206)
        XCTAssertEqual(parsedWrongCR.body, upstream.payload.subdata(in: 0..<65_536), "Wrong-interval chunk 1 bytes must never be written to client")

        upstream.setMode(.valid206)
        let rawWrongCRRec = try await rawLoopbackHttpRequest(url: urlWrongCR, range: "bytes=65536-131071")
        let parsedWrongCRRec = try parseRawHttpResponse(rawWrongCRRec)
        XCTAssertEqual(parsedWrongCRRec.status, 206)
        XCTAssertEqual(parsedWrongCRRec.body, upstream.payload.subdata(in: 65_536..<131_072))
        await proxy.revokeResource(resWrongCR)

        // 4) Chunk 0 returns valid 206, then chunk 1 degrades to HTTP 200 ->
        // First connection MUST close after chunk 0 with EXACTLY ONE HTTP header block (NO second 206/200/502 header!),
        // and fresh follow-up request recovers via bounded 200 streaming with exact bytes & bounded memory!
        upstream.setMode(.degradeTo200AfterChunk0)
        let (resDegrade, urlDegrade) = try await proxy.registerStream(url: mediaUrl, policy: policy)
        let rawDegrade1 = try await rawLoopbackHttpRequest(url: urlDegrade, range: "bytes=0-131071")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawDegrade1), 1, "206->200 degradation mid-stream must NOT write a second HTTP header")
        let parsedDegrade1 = try parseRawHttpResponse(rawDegrade1)
        XCTAssertEqual(parsedDegrade1.status, 206)
        XCTAssertEqual(parsedDegrade1.body, upstream.payload.subdata(in: 0..<65_536))

        // Fresh request #2 recovers cleanly via bounded 200 pass-through
        let rawDegrade2 = try await rawLoopbackHttpRequest(url: urlDegrade, range: "bytes=65536-131071")
        XCTAssertEqual(countOccurrences(of: "HTTP/1.", in: rawDegrade2), 1)
        let parsedDegrade2 = try parseRawHttpResponse(rawDegrade2)
        XCTAssertEqual(parsedDegrade2.status, 206)
        XCTAssertEqual(parsedDegrade2.body, upstream.payload.subdata(in: 65_536..<131_072))

        await proxy.revokeResource(resDegrade)
        let metrics = await proxy.metrics()
        XCTAssertLessThanOrEqual(metrics.peakBufferedBytes, proxy.memoryLimit, "Bounded memory ceiling must be preserved")
        XCTAssertEqual(metrics.currentBufferedBytes, 0)
    }

    // MARK: - Item 6: Manual & Error-Overlay Line Switch Position Policy & Missing-Episode Check

    @MainActor
    func testRound2Item6_ManualAndErrorLineSwitchCarryCurrentPositionAndPromptOnMissingEpisode() async throws {
        let site = CmsSite(key: "sub::s1::vod", name: "换线测试站", type: 1, api: "https://line-test.example/vod")
        let makeEps: (String, Int) -> [CmsEpisode] = { prefix, count in
            (1...count).map { idx in
                CmsEpisode(name: String(format: "第%02d集", idx), url: "https://cdn.example/\(prefix)_ep\(idx).m3u8")
            }
        }
        let video = CmsVideo(
            id: "series_1",
            title: "换线测试剧",
            lines: [
                CmsLine(name: "高速线路A", episodes: makeEps("lineA", 10)),
                CmsLine(name: "备用线路B", episodes: makeEps("lineB", 10)),
                CmsLine(name: "精简线路C", episodes: makeEps("lineC", 5)),
            ]
        )

        let engine = R2MockPlaybackEngine()
        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(
                site: site,
                video: video,
                lineIndex: 0,
                episodeIndex: 0,
                initialSeekMs: 900_000 // Resume from 15:00
            ),
            engine: engine,
            resolver: { target in
                let ep = target.currentEpisode!
                return ResolvedPlayback(originalUrl: ep.url, playableUrl: URL(string: ep.url)!)
            },
            progressRecorder: { _, _, _ in },
            skipIntroSec: 90
        )

        // Start playback resuming at 15:00 (900_000 ms), become ready, then rewind to 05:00 (300_000 ms)
        coordinator.startInitialLoad()
        try await waitUntil { engine.loads.count == 1 }
        XCTAssertEqual(engine.loads[0].initialSeekMs, 900_000)

        engine.markReady(positionMs: 900_000)
        engine.userSeek(toMs: 300_000)

        // Manual line switch from system playback menu (Line A -> Line B) MUST stay at 05:00 (300_000), NOT jump back to 15:00!
        let outcome1 = coordinator.switchVodLine(to: 1)
        XCTAssertEqual(outcome1, .switched(lineIndex: 1, episodeIndex: 0, seekMs: 300_000))
        try await waitUntil { engine.loads.count == 2 }
        XCTAssertEqual(engine.loads[1].url.absoluteString, "https://cdn.example/lineB_ep1.m3u8")
        XCTAssertEqual(engine.loads[1].initialSeekMs, 300_000)

        // Rewind all the way to 00:00 and switch back to Line A -> MUST stay at 0 ms (not 90s intro skip or 300s)
        engine.markReady(positionMs: 300_000)
        engine.userSeek(toMs: 0)
        let outcomeZero = coordinator.switchVodLine(to: 0)
        XCTAssertEqual(outcomeZero, .switched(lineIndex: 0, episodeIndex: 0, seekMs: 0))
        try await waitUntil { engine.loads.count == 3 }
        XCTAssertEqual(engine.loads[2].initialSeekMs, 0)

        // Error-overlay line switch shares the exact same current-position policy:
        // Resume at 15:00 -> rewind to 05:00 -> playback fails -> switchToNextVodLineOutcome carries 05:00!
        coordinator.switchToEpisode(lineIndex: 0, episodeIndex: 2, seekMs: 900_000)
        try await waitUntil { engine.loads.count == 4 }
        engine.markReady(positionMs: 900_000)
        engine.userSeek(toMs: 300_000)
        engine.emitFailure(message: "解码缓冲超时")
        XCTAssertTrue(coordinator.errorIsPlaybackFailure)

        let outcomeErrSwitch = coordinator.switchToNextVodLineOutcome()
        XCTAssertEqual(outcomeErrSwitch, .switched(lineIndex: 1, episodeIndex: 2, seekMs: 300_000))
        try await waitUntil { engine.loads.count == 5 }
        XCTAssertEqual(engine.loads[4].url.absoluteString, "https://cdn.example/lineB_ep3.m3u8")
        XCTAssertEqual(engine.loads[4].initialSeekMs, 300_000)

        // Target line missing current episode (watching Line A EP 8, switching to Line C which only has 5 episodes):
        coordinator.switchToEpisode(lineIndex: 0, episodeIndex: 7, seekMs: 420_000)
        try await waitUntil { engine.loads.count == 6 }
        engine.markReady(positionMs: 420_000)
        let activeTokenBeforeMissing = engine.activeItemToken

        let missingOutcome = coordinator.switchVodLine(to: 2)
        guard case .missingEpisode(let info) = missingOutcome else {
            return XCTFail("Expected .missingEpisode when target line C only has 5 episodes and user is on EP 8")
        }
        XCTAssertEqual(info.targetLineIndex, 2)
        XCTAssertEqual(info.targetLineName, "精简线路C")
        XCTAssertEqual(info.requestedEpisodeIndex, 7)
        XCTAssertEqual(info.requestedEpisodeName, "第08集")
        XCTAssertEqual(info.availableEpisodeCount, 5)
        XCTAssertEqual(info.carrySeekMs, 420_000)
        // Current playback MUST remain completely undisturbed while prompt is shown!
        XCTAssertEqual(coordinator.activeLoaded?.lineIndex, 0)
        XCTAssertEqual(coordinator.activeLoaded?.episodeIndex, 7)
        XCTAssertEqual(engine.activeItemToken, activeTokenBeforeMissing)

        // User explicitly chooses "改播该线路第 5 集" -> switches cleanly starting from 0:00
        XCTAssertTrue(coordinator.forceSwitchVodLine(to: 2, episodeIndex: 4, seekMs: 0))
        try await waitUntil { engine.loads.count == 7 }
        XCTAssertEqual(engine.loads[6].url.absoluteString, "https://cdn.example/lineC_ep5.m3u8")
        XCTAssertEqual(engine.loads[6].initialSeekMs, 0)
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        timeoutNs: UInt64 = 3_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNs {
                XCTFail("Timed out waiting for async test condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fetchUrlRange(_ url: URL, range: String) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue(range, forHTTPHeaderField: "Range")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        return (http.statusCode, data)
    }

    private final class RawLoopbackHttpCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let conn: NWConnection
        private var finished = false
        private var collected = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(conn: NWConnection) {
            self.conn = conn
        }

        func start(reqData: Data, queue: DispatchQueue, continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.conn.send(content: reqData, completion: .contentProcessed { sendErr in
                        if let sendErr {
                            self.complete(.failure(sendErr))
                        } else {
                            self.receiveNext()
                        }
                    })
                case .failed(let err):
                    let snapshot = self.snapshotData()
                    if !snapshot.isEmpty {
                        self.complete(.success(snapshot))
                    } else {
                        self.complete(.failure(err))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }

        private func receiveNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
                if let chunk, !chunk.isEmpty {
                    self.appendData(chunk)
                }
                if isComplete || error != nil {
                    self.complete(.success(self.snapshotData()))
                } else {
                    self.receiveNext()
                }
            }
        }

        private func appendData(_ chunk: Data) {
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        private func snapshotData() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return collected
        }

        private func complete(_ result: Result<Data, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            conn.stateUpdateHandler = nil
            conn.cancel()
            switch result {
            case .success(let d): cont?.resume(returning: d)
            case .failure(let e): cont?.resume(throwing: e)
            }
        }
    }

    private func rawLoopbackHttpRequest(url: URL, range: String?) async throws -> Data {
        guard let portNum = url.port, let nwPort = NWEndpoint.Port(rawValue: UInt16(portNum)) else {
            throw MarcoError.invalidFormat("Invalid loopback URL port")
        }
        let conn = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        let q = DispatchQueue(label: "com.pilipala.marcoMovie.tests.raw-http")

        var reqLines = [
            "GET \(url.path) HTTP/1.1",
            "Host: 127.0.0.1:\(portNum)",
            "Connection: close",
        ]
        if let range {
            reqLines.append("Range: \(range)")
        }
        reqLines.append("")
        reqLines.append("")
        let reqData = Data(reqLines.joined(separator: "\r\n").utf8)
        let collector = RawLoopbackHttpCollector(conn: conn)

        return try await withCheckedThrowingContinuation { continuation in
            collector.start(reqData: reqData, queue: q, continuation: continuation)
        }
    }

    private func parseRawHttpResponse(_ raw: Data) throws -> (status: Int, headers: String, body: Data) {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = raw.range(of: sep) else {
            throw MarcoError.invalidFormat("Raw response missing HTTP header terminator")
        }
        let hdrText = String(decoding: raw.subdata(in: 0..<range.lowerBound), as: UTF8.self)
        let firstLine = hdrText.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw MarcoError.invalidFormat("Malformed HTTP status line: \(firstLine)")
        }
        let body = raw.subdata(in: range.upperBound..<raw.count)
        return (code, hdrText, body)
    }

    private func countOccurrences(of needle: String, in data: Data) -> Int {
        let needleData = Data(needle.utf8)
        guard !needleData.isEmpty else { return 0 }
        var count = 0
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let found = data.range(of: needleData, options: [], in: searchStart..<data.endIndex)
        {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}

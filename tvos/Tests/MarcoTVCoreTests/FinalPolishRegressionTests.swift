// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network
import XCTest
@testable import MarcoTVCore

// MARK: - Helpers

private final class FinalTestBox<Value>: @unchecked Sendable {
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

private final class FinalStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = FinalTestBox<Handler?>(nil)

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

// MARK: - Controlled Mock WebDAV Server for Cross-Device, Privacy Scrub & TOCTOU Tests

private actor FinalMockWebDavServer {
    struct RecordedPut: Sendable {
        let ifMatch: String?
        let ifNoneMatch: String?
        let statusReturned: Int
    }

    var payload: String?
    var etag: String?
    var putHistory: [RecordedPut] = []
    var unconditionalPutCount: Int = 0

    // Optional fault injection for first-create TOCTOU test
    var rejectIfNoneMatchStatus: Int?
    var injectAfterNext404Get: (payload: String, etag: String)?
    private var pendingPostProbeInject = false

    // Optional pause gate for final-PUT pending-changes test
    var pauseOnPutNumber: Int?
    private var hasPausedPut = false
    private var preResumedPut = false
    private var resumeGate: CheckedContinuation<Void, Never>?

    init(initialPayload: String? = nil, initialEtag: String? = nil) {
        self.payload = initialPayload
        self.etag = initialEtag
    }

    func configureFirstCreateRejectWithRace(
        rejectStatus: Int,
        deviceBPayloadAfterProbe404: String,
        deviceBEtag: String
    ) {
        rejectIfNoneMatchStatus = rejectStatus
        injectAfterNext404Get = (deviceBPayloadAfterProbe404, deviceBEtag)
        pendingPostProbeInject = false
    }

    func configurePauseOnPut(_ number: Int?) {
        pauseOnPutNumber = number
        hasPausedPut = false
        preResumedPut = false
    }

    func waitUntilPutPaused(timeoutNs: UInt64 = 5_000_000_000) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !hasPausedPut {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNs {
                throw MarcoError.networkFailure("Timed out waiting for mock WebDAV PUT pause")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func resumePausedPut() {
        if let gate = resumeGate {
            resumeGate = nil
            gate.resume()
        } else {
            preResumedPut = true
        }
    }

    func snapshot() -> (payload: String?, etag: String?, puts: [RecordedPut], unconditionalPuts: Int) {
        (payload, etag, putHistory, unconditionalPutCount)
    }

    func handle(method: String, headers: [String: String], body: Data?) async -> WebDavHttpResponse {
        switch method {
        case "MKCOL":
            return WebDavHttpResponse(statusCode: 201)

        case "GET":
            if let bodyText = payload {
                var respHeaders: [String: String] = [:]
                if let tag = etag { respHeaders["ETag"] = tag }
                return WebDavHttpResponse(statusCode: 200, headers: respHeaders, body: Data(bodyText.utf8))
            }
            if pendingPostProbeInject, let race = injectAfterNext404Get {
                // Probe GET returns 404, and IMMEDIATELY afterward Device B wins the race and creates the file!
                pendingPostProbeInject = false
                injectAfterNext404Get = nil
                payload = race.payload
                etag = race.etag
            }
            return WebDavHttpResponse(statusCode: 404)

        case "PUT":
            let putIndex = putHistory.count + 1
            let ifMatch = headers["If-Match"]
            let ifNoneMatch = headers["If-None-Match"]
            if ifMatch == nil && ifNoneMatch == nil {
                unconditionalPutCount += 1
            }

            if pauseOnPutNumber == putIndex {
                hasPausedPut = true
                if !preResumedPut {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if preResumedPut {
                            preResumedPut = false
                            cont.resume()
                        } else {
                            resumeGate = cont
                        }
                    }
                } else {
                    preResumedPut = false
                }
            }

            if ifNoneMatch == "*" {
                if let rejectStatus = rejectIfNoneMatchStatus {
                    rejectIfNoneMatchStatus = nil
                    pendingPostProbeInject = (injectAfterNext404Get != nil)
                    putHistory.append(RecordedPut(ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, statusReturned: rejectStatus))
                    return WebDavHttpResponse(statusCode: rejectStatus)
                }
                if payload != nil {
                    putHistory.append(RecordedPut(ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, statusReturned: 412))
                    return WebDavHttpResponse(statusCode: 412)
                }
            } else if let expected = ifMatch {
                if etag == nil || expected != etag {
                    putHistory.append(RecordedPut(ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, statusReturned: 412))
                    return WebDavHttpResponse(statusCode: 412)
                }
            }

            payload = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let nextTag = "\"final-v\(putIndex)\""
            etag = nextTag
            putHistory.append(RecordedPut(ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, statusReturned: 201))
            return WebDavHttpResponse(statusCode: 201, headers: ["ETag": nextTag])

        default:
            return WebDavHttpResponse(statusCode: 405)
        }
    }
}

private final class FinalMockWebDavTransport: WebDavTransportProtocol, @unchecked Sendable {
    let server: FinalMockWebDavServer

    init(server: FinalMockWebDavServer) {
        self.server = server
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> WebDavHttpResponse {
        await server.handle(method: method, headers: headers, body: body)
    }
}

// MARK: - Slow Loopback HLS Server for Item 4 Header Proxy Cancellation Test

private final class SlowHlsLoopbackServer: @unchecked Sendable {
    let fastSegmentPayload: Data
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tests.slow-hls", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var slowConnections: [NWConnection] = []
    private var slowStartedCount: Int = 0
    private var slowCancelledCount: Int = 0
    private var fastServedCount: Int = 0

    init() {
        var ts = [UInt8](repeating: 0, count: 188 * 16)
        for i in 0..<16 {
            ts[i * 188] = 0x47
            ts[i * 188 + 1] = UInt8(i & 0xFF)
        }
        self.fastSegmentPayload = Data(ts)
    }

    deinit {
        stop()
    }

    func snapshot() -> (slowStarted: Int, slowCancelled: Int, fastServed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (slowStartedCount, slowCancelledCount, fastServedCount)
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
            let resumeBox = FinalTestBox<Bool>(false)
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let shouldResume = resumeBox.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(returning: nwListener.port?.rawValue ?? 0)
                    }
                case .failed(let err):
                    let shouldResume = resumeBox.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: err)
                    }
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        setBound(listener: nwListener, port: boundPort)
        return boundPort
    }

    private func setBound(listener: NWListener, port: UInt16) {
        lock.lock()
        self.listener = listener
        self.port = port
        lock.unlock()
    }

    func stop() {
        let (active, conns) = { () -> (NWListener?, [NWConnection]) in
            lock.lock()
            defer { lock.unlock() }
            let l = listener
            listener = nil
            port = 0
            let c = slowConnections
            slowConnections.removeAll()
            return (l, c)
        }()
        active?.cancel()
        for c in conns { c.cancel() }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHeader(conn: conn, acc: Data())
    }

    private func readHeader(conn: NWConnection, acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, err in
            guard let self, err == nil else {
                conn.cancel()
                return
            }
            var buf = acc
            if let chunk { buf.append(chunk) }
            if let sep = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let text = String(decoding: buf.subdata(in: 0..<sep.lowerBound), as: UTF8.self)
                self.dispatch(headerText: text, conn: conn)
            } else if isComplete {
                conn.cancel()
            } else {
                self.readHeader(conn: conn, acc: buf)
            }
        }
    }

    private func dispatch(headerText: String, conn: NWConnection) {
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        let path = parts.count >= 2 ? parts[1] : "/"

        if path.hasSuffix("slow_master.m3u8") {
            let body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nslow_seg.ts\n#EXT-X-ENDLIST\n".utf8)
            sendComplete(conn: conn, contentType: "application/vnd.apple.mpegurl", body: body)
            return
        }
        if path.hasSuffix("fast_master.m3u8") {
            let body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nfast_seg.ts\n#EXT-X-ENDLIST\n".utf8)
            sendComplete(conn: conn, contentType: "application/vnd.apple.mpegurl", body: body)
            return
        }
        if path.hasSuffix("fast_seg.ts") {
            lock.lock()
            fastServedCount += 1
            lock.unlock()
            sendComplete(conn: conn, contentType: "video/mp2t", body: fastSegmentPayload)
            return
        }
        if path.hasSuffix("slow_seg.ts") {
            lock.lock()
            slowStartedCount += 1
            slowConnections.append(conn)
            lock.unlock()

            let cancelledFlag = FinalTestBox<Bool>(false)
            let markCancelled: @Sendable () -> Void = { [weak self] in
                let first = cancelledFlag.withLock { already -> Bool in
                    guard !already else { return false }
                    already = true
                    return true
                }
                guard first, let self else { return }
                self.lock.lock()
                self.slowCancelledCount += 1
                self.lock.unlock()
                conn.cancel()
            }

            // Send headers claiming 2 MiB + tiny initial chunk, then drip slowly while watching for peer abort.
            let hdr = [
                "HTTP/1.1 200 OK",
                "Content-Type: video/mp2t",
                "Content-Length: 2097152",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            var initial = Data(hdr.utf8)
            initial.append(Data(repeating: 0x47, count: 188))
            conn.send(content: initial, completion: .contentProcessed { err in
                if err != nil { markCancelled() }
            })
            conn.stateUpdateHandler = { state in
                if case .failed = state { markCancelled() }
                if case .cancelled = state { markCancelled() }
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, err in
                if isComplete || err != nil {
                    markCancelled()
                }
            }
            return
        }

        let notFound = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        conn.send(content: notFound, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendComplete(conn: NWConnection, contentType: String, body: Data) {
        let hdr = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var pkt = Data(hdr.utf8)
        pkt.append(body)
        conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Mock Playback Engine

@MainActor
private final class FinalMockPlaybackEngine: PlaybackEngineAdapterProtocol {
    struct LoadCall: Equatable {
        let token: UInt64
        let url: URL
        let initialSeekMs: Int
    }

    var activeItemToken: UInt64?
    var hasReadyCurrentItem: Bool = false
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)?
    var onPlaybackEnded: ((_ token: UInt64) -> Void)?
    var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)?

    private(set) var loads: [LoadCall] = []

    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float) {
        activeItemToken = token
        hasReadyCurrentItem = false
        currentTimeMs = 0
        loads.append(LoadCall(token: token, url: url, initialSeekMs: initialSeekMs))
    }

    func markReady(positionMs: Int, durationMs: Int = 3_600_000) {
        hasReadyCurrentItem = true
        currentTimeMs = positionMs
        self.durationMs = durationMs
        if let tok = activeItemToken {
            onProgressTick?(tok, positionMs, durationMs)
        }
    }

    func stopCurrentItem() {
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

// MARK: - Final Polish Regression Tests (Items 1-4)

final class FinalPolishRegressionTests: XCTestCase {

    // MARK: - Item 1: Cross-Device Same-URL Continuity + Deleted-Duplicate Ambiguity + Single-Card Legacy Upgrade

    func testFinalItem1_TwoDevicesSameUrlResumeUnfavoriteAndSyncBack() async throws {
        let sharedUrl = "https://shared-tv.example/sub.json"
        let sharedRaw = #"{"sites":[{"key":"shared_cms","name":"共享电影站","type":1,"api":"https://shared-cms.example/vod"}]}"#

        defer { FinalStubURLProtocol.uninstall() }
        FinalStubURLProtocol.install { request in
            let url = request.url ?? URL(string: "https://shared-cms.example/vod")!
            let json = #"{"list":[{"vod_id":"42","vod_name":"沙丘·双机续播","vod_pic":"https://cdn.example/dune.jpg","vod_play_from":"4K线","vod_play_url":"正片$https://cdn.example/dune.m3u8"}]}"#
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.protocolClasses = [FinalStubURLProtocol.self]
        let client = CmsClient(session: URLSession(configuration: sessionCfg))

        // Part A: Fresh imports on two independent storages produce identical deterministic IDs
        let dirFreshA = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalFreshA_\(UUID().uuidString)", isDirectory: true)
        let dirFreshB = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalFreshB_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirFreshA)
            try? FileManager.default.removeItem(at: dirFreshB)
        }
        let freshA = TvStorageManager(cachesDirectory: dirFreshA, keychain: InMemoryKeychainStore())
        let freshB = TvStorageManager(cachesDirectory: dirFreshB, keychain: InMemoryKeychainStore())
        let (freshSubA, _) = try freshA.upsertSubscription(name: "客厅TV", url: sharedUrl, rawContent: sharedRaw, nowMs: 1_000)
        let (freshSubB, _) = try freshB.upsertSubscription(name: "卧室TV", url: sharedUrl, rawContent: sharedRaw, nowMs: 1_100)
        XCTAssertEqual(freshSubA.id, freshSubB.id, "Two devices importing the same URL must derive identical deterministic subscription IDs")
        XCTAssertEqual(freshA.mergedConfig().publicAvailableSites.first?.key, freshB.mergedConfig().publicAvailableSites.first?.key)

        // Part B: Two independent devices that ALREADY hold DIFFERENT local subscription IDs for the same URL
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalDevA_\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalDevB_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let storageA = TvStorageManager(cachesDirectory: dirA, keychain: InMemoryKeychainStore())
        let storageB = TvStorageManager(cachesDirectory: dirB, keychain: InMemoryKeychainStore())

        let (subA, _) = try storageA.upsertSubscription(id: "sub_legacy_dev_a", name: "客厅源", url: sharedUrl, rawContent: sharedRaw, nowMs: 1_000)
        let (subB, _) = try storageB.upsertSubscription(id: "sub_legacy_dev_b", name: "卧室源", url: sharedUrl, rawContent: sharedRaw, nowMs: 1_200)
        XCTAssertNotEqual(subA.id, subB.id)

        let davCfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "u",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try storageA.saveWebDavConfig(davCfg)
        try storageB.saveWebDavConfig(davCfg)

        let server = FinalMockWebDavServer()
        let serviceA = WebDavSyncService(storage: storageA, transport: FinalMockWebDavTransport(server: server))
        let serviceB = WebDavSyncService(storage: storageB, transport: FinalMockWebDavTransport(server: server))

        // Device A watches & favorites movie 42, then syncs
        let siteA = try XCTUnwrap(storageA.mergedConfig().publicAvailableSites.first)
        let movie42 = CmsVideo(id: "42", title: "沙丘·双机续播", poster: "https://cdn.example/dune.jpg")
        storageA.upsertWatchHistory(
            WatchHistoryItem(
                site: siteA.key,
                id: "42",
                title: movie42.title,
                poster: movie42.poster,
                line: "4K线",
                episode: "正片",
                index: 0,
                position: 90_000,
                duration: 7_200_000,
                updated: 2_000
            )
        )
        XCTAssertTrue(storageA.toggleFavorite(site: siteA.key, video: movie42, nowMs: 2_100))
        _ = try await serviceA.syncNow()

        // Device B syncs -> MUST be able to open & resume A's history and favorite without "原片源不可用"!
        _ = try await serviceB.syncNow()
        let cfgB = storageB.mergedConfig()
        let siteB = try XCTUnwrap(cfgB.publicAvailableSites.first)
        let histOnB = try XCTUnwrap(MediaEntryResolver.publicVisibleWatchHistory(storageB.watchHistory(), in: cfgB).first)
        let favOnB = try XCTUnwrap(MediaEntryResolver.publicVisibleFavorites(storageB.favorites(), in: cfgB).first)

        let resolvedHistB = try await MediaEntryResolver.resolveWatchHistoryEntry(histOnB, config: cfgB, cmsClient: client)
        guard case .ready(let bSiteOut, let bVideoOut, let bResume) = resolvedHistB else {
            return XCTFail("Device B must resolve Device A's synced watch history for the same subscription URL")
        }
        XCTAssertEqual(bSiteOut.key, siteB.key)
        XCTAssertEqual(bVideoOut.title, "沙丘·双机续播")
        XCTAssertEqual(bResume?.resumePosition, 90_000)

        let resolvedFavB = try await MediaEntryResolver.resolveFavoriteEntry(favOnB, config: cfgB, watchHistory: storageB.watchHistory(), cmsClient: client)
        guard case .ready = resolvedFavB else {
            return XCTFail("Device B must resolve Device A's synced favorite cleanly")
        }

        // Device B resumes to 210s AND un-favorites movie 42, then syncs back to Device A
        storageB.upsertWatchHistory(
            WatchHistoryItem(
                site: siteB.key,
                id: "42",
                title: movie42.title,
                poster: movie42.poster,
                line: "4K线",
                episode: "正片",
                index: 0,
                position: 210_000,
                duration: 7_200_000,
                updated: 5_000
            )
        )
        XCTAssertFalse(storageB.toggleFavorite(site: siteB.key, video: movie42, nowMs: 5_100))
        _ = try await serviceB.syncNow()

        // Device A syncs -> receives 210s progress (single card!) AND favorite removal!
        _ = try await serviceA.syncNow()
        let histListA = storageA.watchHistory().filter { $0.id == "42" }
        XCTAssertEqual(histListA.count, 1, "Device A must keep exactly one watch history card after round-trip sync")
        XCTAssertEqual(histListA.first?.position, 210_000)
        XCTAssertTrue(storageA.favorites().filter { $0.id == "42" }.isEmpty, "Device B's unfavorite must propagate back to Device A")
    }

    func testFinalItem1_DeletingDuplicateSubPreservesLegacyAmbiguityAndUnambiguousLegacyUpgradesToSingleCard() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoFinalLegacyAmbig_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychainStore()

        let rawA = #"{"sites":[{"key":"cms","name":"A重名站","type":1,"api":"https://dup-a.example/vod"}]}"#
        let rawB = #"{"sites":[{"key":"cms","name":"B重名站","type":1,"api":"https://dup-b.example/vod"}]}"#
        let rawSolo = #"{"sites":[{"key":"solo_cms","name":"唯一旧站","type":1,"api":"https://solo-legacy.example/vod"}]}"#

        let requestedHosts = FinalTestBox<[String]>([])
        defer { FinalStubURLProtocol.uninstall() }
        FinalStubURLProtocol.install { request in
            let url = request.url ?? URL(string: "https://dup-b.example/vod")!
            let host = url.host ?? ""
            requestedHosts.withLock { $0.append(host) }
            if host == "dup-b.example" {
                let json = #"{"list":[{"vod_id":"42","vod_name":"B站42·不能串片","vod_play_from":"B线","vod_play_url":"正片$https://cdn.example/b42.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "solo-legacy.example" {
                let json = #"{"list":[{"vod_id":"7","vod_name":"唯一旧片7","vod_play_from":"S线","vod_play_url":"正片$https://cdn.example/s7.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.protocolClasses = [FinalStubURLProtocol.self]
        let client = CmsClient(session: URLSession(configuration: sessionCfg))

        let storage = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let (subA, _) = try storage.upsertSubscription(id: "sub_dup_a", name: "重名订阅A", url: "https://dup-a.example/sub.json", rawContent: rawA, nowMs: 1_000)
        let (subB, _) = try storage.upsertSubscription(id: "sub_dup_b", name: "重名订阅B", url: "https://dup-b.example/sub.json", rawContent: rawB, nowMs: 1_100)
        _ = try storage.upsertSubscription(id: "sub_solo_1", name: "唯一订阅", url: "https://solo-legacy.example/sub.json", rawContent: rawSolo, nowMs: 1_200)

        // Seed ambiguous legacy bare record ("cms" / 42) AND unambiguous legacy bare record ("solo_cms" / 7)
        let legacyAmbigHist = WatchHistoryItem(site: "cms", id: "42", title: "旧版不确定42", poster: "", line: "", episode: "", index: 0, position: 75_000, duration: 3_000_000, updated: 1_500)
        storage.upsertWatchHistory(legacyAmbigHist)
        _ = storage.toggleFavorite(site: "cms", video: CmsVideo(id: "42", title: "旧版不确定42"), nowMs: 1_550)

        let legacySoloHist = WatchHistoryItem(site: "solo_cms", id: "7", title: "唯一旧片7", poster: "", line: "S线", episode: "正片", index: 0, position: 30_000, duration: 3_000_000, updated: 1_600)
        storage.upsertWatchHistory(legacySoloHist)
        _ = storage.toggleFavorite(site: "solo_cms", video: CmsVideo(id: "7", title: "唯一旧片7"), nowMs: 1_650)

        // Delete subscription A! Remaining subscription B must NOT hijack the ambiguous legacy bare record "cms"!
        storage.removeSubscription(id: subA.id)

        // Cold restart to ensure ambiguity metadata survives disk + Keychain Anchor persistence
        let restarted = TvStorageManager(cachesDirectory: dir, keychain: keychain)
        let cfgAfterDelete = restarted.mergedConfig()

        requestedHosts.withLock { $0.removeAll() }
        let ambigRes = try await MediaEntryResolver.resolveWatchHistoryEntry(legacyAmbigHist, config: cfgAfterDelete, cmsClient: client)
        guard case .sourceUnavailable(_, let ambigReason) = ambigRes else {
            return XCTFail("Deleting subA must NOT auto-assign ambiguous legacy bare 'cms' record to remaining subB")
        }
        XCTAssertTrue(ambigReason.contains("重名"))
        XCTAssertTrue(requestedHosts.withLock { $0.isEmpty }, "Must NEVER query remaining subB for ambiguous bare 'cms' record")
        XCTAssertTrue(restarted.watchHistory().contains(where: { $0.site == "cms" && $0.id == "42" }), "Ambiguous legacy record must remain preserved")

        // Meanwhile B's own canonical key still resolves B's movie 42 normally
        let bCanonicalKey = CmsSite.canonicalScopedKey(rawKey: "cms", subscriptionId: subB.id)
        let bRecord = WatchHistoryItem(site: bCanonicalKey, id: "42", title: "B站42", poster: "", line: "B线", episode: "正片", index: 0, position: 40_000, duration: 3_000_000, updated: 2_000)
        let bRes = try await MediaEntryResolver.resolveWatchHistoryEntry(bRecord, config: cfgAfterDelete, cmsClient: client)
        guard case .ready(_, let bVid, _) = bRes else {
            return XCTFail("Remaining subB's own canonical record must remain playable")
        }
        XCTAssertEqual(bVid.title, "B站42·不能串片")

        // Unambiguous legacy bare record ("solo_cms" / 7): resume -> consolidates to EXACTLY ONE canonical card + tombstone!
        let soloRes = try await MediaEntryResolver.resolveWatchHistoryEntry(legacySoloHist, config: cfgAfterDelete, cmsClient: client)
        guard case .ready(let soloSite, let soloVid, let soloResume) = soloRes else {
            return XCTFail("Unambiguous legacy bare record must resolve cleanly")
        }
        XCTAssertEqual(soloResume?.resumePosition, 30_000)

        restarted.upsertWatchHistory(
            WatchHistoryItem(
                site: soloSite.key,
                id: soloVid.id,
                title: soloVid.title,
                poster: soloVid.poster,
                line: "S线",
                episode: "正片",
                index: 0,
                position: 150_000,
                duration: 3_000_000,
                updated: 3_000
            )
        )
        let soloCards = restarted.watchHistory().filter { $0.id == "7" }
        XCTAssertEqual(soloCards.count, 1, "Resuming an unambiguous legacy record must leave only ONE card")
        XCTAssertEqual(soloCards.first?.site, soloSite.key)
        XCTAssertEqual(soloCards.first?.position, 150_000)
        XCTAssertNotNil(restarted.tombstones()["hist:solo_cms\n7"], "Superseded bare key must be tombstoned for WebDAV sync")

        // Un-favoriting unambiguous legacy favorite via canonical site key leaves zero cards and records fav tombstone
        XCTAssertFalse(restarted.toggleFavorite(site: soloSite.key, video: soloVid, nowMs: 3_100))
        XCTAssertTrue(restarted.favorites().filter { $0.id == "7" }.isEmpty)
        XCTAssertNotNil(restarted.tombstones()["fav:solo_cms\n7"])
    }

    // MARK: - Item 2: Private Transition Scrubs WebDAV/LAN QR + Deleted Source Stays Hidden + Live Index & In-Flight Guards

    func testFinalItem2_PrivateTransitionScrubsWebDavAndLanQrAndDeletedPrivateNeverLeaks() async throws {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalPrivA_\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalPrivB_\(UUID().uuidString)", isDirectory: true)
        let dirC = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalPrivC_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: dirC)
        }
        let keychainA = InMemoryKeychainStore()
        let storageA = TvStorageManager(cachesDirectory: dirA, keychain: keychainA)
        let storageB = TvStorageManager(cachesDirectory: dirB, keychain: InMemoryKeychainStore())
        let storageC = TvStorageManager(cachesDirectory: dirC, keychain: InMemoryKeychainStore())

        let rawSecret = #"{"sites":[{"key":"sec_site","name":"后续私密站","type":1,"api":"https://sec.example/vod"}]}"#
        let rawPublic = #"{"sites":[{"key":"pub_site","name":"普通公开站","type":1,"api":"https://pub.example/vod"}]}"#
        let secretPoster = "https://secret-poster.invalid/hidden.jpg"
        let publicPoster = "https://public-poster.invalid/visible.jpg"

        let (subSecret, _) = try storageA.upsertSubscription(id: "sub_sec_1", name: "私密候选源", url: "https://sec.example/sub.json", rawContent: rawSecret, isPrivate: false, nowMs: 1_000)
        let (subPublic, _) = try storageA.upsertSubscription(id: "sub_pub_1", name: "公开源", url: "https://pub.example/sub.json", rawContent: rawPublic, isPrivate: false, nowMs: 1_100)

        let secSiteKey = CmsSite.canonicalScopedKey(rawKey: "sec_site", subscriptionId: subSecret.id)
        let pubSiteKey = CmsSite.canonicalScopedKey(rawKey: "pub_site", subscriptionId: subPublic.id)

        storageA.upsertWatchHistory(
            WatchHistoryItem(site: pubSiteKey, id: "p1", title: "公开纪录片", poster: publicPoster, line: "线1", episode: "第1集", index: 0, position: 20_000, duration: 1_000_000, updated: 2_000)
        )
        storageA.upsertWatchHistory(
            WatchHistoryItem(site: secSiteKey, id: "s1", title: "私密影片标题", poster: secretPoster, line: "线1", episode: "第1集", index: 0, position: 120_000, duration: 3_000_000, updated: 3_000)
        )
        _ = storageA.toggleFavorite(site: pubSiteKey, video: CmsVideo(id: "p1", title: "公开纪录片", poster: publicPoster), nowMs: 2_100)
        _ = storageA.toggleFavorite(site: secSiteKey, video: CmsVideo(id: "s1", title: "私密影片标题", poster: secretPoster), nowMs: 3_100)

        let davCfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "u",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try storageA.saveWebDavConfig(davCfg)
        try storageB.saveWebDavConfig(davCfg)

        // Step 1: Sync while STILL public so remote WebDAV & Device B hold old records!
        let davServer = FinalMockWebDavServer()
        let davA = WebDavSyncService(storage: storageA, transport: FinalMockWebDavTransport(server: davServer))
        let davB = WebDavSyncService(storage: storageB, transport: FinalMockWebDavTransport(server: davServer))
        _ = try await davA.syncNow()
        _ = try await davB.syncNow()
        XCTAssertTrue(storageB.watchHistory().contains(where: { $0.title == "私密影片标题" }))

        // Step 2: Device A marks subSecret as PRIVATE -> syncs to WebDAV!
        var subsA = storageA.subscriptions()
        subsA[subsA.firstIndex(where: { $0.id == subSecret.id })!].isPrivate = true
        storageA.saveSubscriptions(subsA)

        _ = try await davA.syncNow()

        // Remote WebDAV payload must have scrubbed old private title, poster & subscription!
        let scrubSnap = await davServer.snapshot()
        let remoteAfterScrub = try XCTUnwrap(scrubSnap.payload)
        XCTAssertFalse(remoteAfterScrub.contains("私密影片标题"), "Remote WebDAV must not retain private title after source turns private")
        XCTAssertFalse(remoteAfterScrub.contains(secretPoster), "Remote WebDAV must not retain private poster URL")
        XCTAssertFalse(remoteAfterScrub.contains("https://sec.example/sub.json"), "Remote WebDAV must scrub now-private subscription")
        XCTAssertTrue(remoteAfterScrub.contains("公开纪录片"))

        // Device A's local private breakpoint & favorite MUST be preserved!
        XCTAssertEqual(storageA.watchHistory().first(where: { $0.id == "s1" })?.position, 120_000)
        XCTAssertTrue(storageA.favorites().contains(where: { $0.id == "s1" }))

        // Device B syncs from WebDAV -> old private records are scrubbed; zero private titles/posters/backdrop!
        _ = try await davB.syncNow()
        let cfgB = storageB.mergedConfig()
        let pubHistB = MediaEntryResolver.publicVisibleWatchHistory(storageB.watchHistory(), in: cfgB)
        let pubFavsB = MediaEntryResolver.publicVisibleFavorites(storageB.favorites(), in: cfgB)
        let backdropB = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: true,
            publicDiscoverVideos: [],
            publicWatchHistory: pubHistB,
            config: cfgB
        )
        XCTAssertFalse(pubHistB.contains(where: { $0.title == "私密影片标题" }))
        XCTAssertFalse(pubFavsB.contains(where: { $0.title == "私密影片标题" }))
        XCTAssertEqual(backdropB, publicPoster)

        // Step 3: LAN QR sync endpoint (`/configure/<token>/sync`) AND Backup export on Device A must leak ZERO private records
        let lanA = LanConfigServer(storage: storageA, syncService: davA)
        defer { lanA.stop() }
        _ = try await lanA.start(loopbackOnly: true)
        let lanSyncUrl = URL(string: "\(lanA.configureUrl(forHost: "127.0.0.1"))/sync")!
        let (lanData, lanResp) = try await URLSession.shared.data(from: lanSyncUrl)
        XCTAssertEqual((lanResp as? HTTPURLResponse)?.statusCode, 200)
        let lanSyncJson = String(decoding: lanData, as: UTF8.self)
        XCTAssertFalse(lanSyncJson.contains("私密影片标题"))
        XCTAssertFalse(lanSyncJson.contains(secretPoster))

        let backupJsonA = try storageA.exportBackupJson()
        XCTAssertFalse(backupJsonA.contains("私密影片标题"))
        XCTAssertFalse(backupJsonA.contains(secretPoster))

        // Step 4: Even if a brand-new Device C somehow receives a foreign/unknown-source record, fail-closed display hides it!
        storageC.upsertWatchHistory(
            WatchHistoryItem(site: "sub::sub_stranger_priv::unknown_src", id: "x9", title: "陌生私密片", poster: secretPoster, line: "", episode: "", index: 0, position: 50_000, duration: 1_000_000, updated: 4_000)
        )
        _ = storageC.toggleFavorite(site: "sub::sub_stranger_priv::unknown_src", video: CmsVideo(id: "x9", title: "陌生私密片", poster: secretPoster), nowMs: 4_100)
        let cfgC = storageC.mergedConfig()
        XCTAssertTrue(MediaEntryResolver.publicVisibleWatchHistory(storageC.watchHistory(), in: cfgC).isEmpty, "New device must fail-closed and hide stranger/unverified sources")
        XCTAssertTrue(MediaEntryResolver.publicVisibleFavorites(storageC.favorites(), in: cfgC).isEmpty)
        XCTAssertEqual(
            MediaEntryResolver.resolvePublicBackdropPosterUrl(ambientPosterSync: true, publicDiscoverVideos: [], publicWatchHistory: storageC.watchHistory(), config: cfgC),
            ""
        )

        // Step 5: Device A deletes the private subscription locally + cold restart -> private cards & poster stay hidden and never sync out!
        storageA.removeSubscription(id: subSecret.id)
        let restartedA = TvStorageManager(cachesDirectory: dirA, keychain: keychainA)
        let cfgAfterDelA = restartedA.mergedConfig()
        XCTAssertFalse(MediaEntryResolver.publicVisibleWatchHistory(restartedA.watchHistory(), in: cfgAfterDelA).contains(where: { $0.id == "s1" }))
        XCTAssertFalse(MediaEntryResolver.publicVisibleFavorites(restartedA.favorites(), in: cfgAfterDelA).contains(where: { $0.id == "s1" }))
        let backdropAfterDelA = MediaEntryResolver.resolvePublicBackdropPosterUrl(
            ambientPosterSync: true,
            publicDiscoverVideos: [],
            publicWatchHistory: restartedA.watchHistory(),
            config: cfgAfterDelA
        )
        XCTAssertNotEqual(backdropAfterDelA, secretPoster)
        let exportedAfterDelA = try WebDavSyncService(storage: restartedA).exportSyncPayload()
        XCTAssertFalse(exportedAfterDelA.contains("私密影片标题"))
        XCTAssertFalse(exportedAfterDelA.contains(secretPoster))
    }

    func testFinalItem2_LiveSourceSameIndexShiftAndInFlightSlowRequestsDroppedOnPrivacyToggle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoFinalLiveInFlight_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = TvStorageManager(cachesDirectory: dir, keychain: InMemoryKeychainStore())

        let rawA = #"{"sites":[{"key":"site_a","name":"A站","type":1,"api":"https://a.example/vod"}],"lives":[{"name":"A直播","url":"https://a.example/live.m3u"}]}"#
        let rawB = #"{"sites":[{"key":"site_b","name":"B站","type":1,"api":"https://b.example/vod"}],"lives":[{"name":"B直播","url":"https://b.example/live.m3u"}]}"#

        let (subA, _) = try storage.upsertSubscription(id: "sub_live_a", name: "订阅A", url: "https://a.example/sub.json", rawContent: rawA, isPrivate: false, nowMs: 1_000)
        _ = try storage.upsertSubscription(id: "sub_live_b", name: "订阅B", url: "https://b.example/sub.json", rawContent: rawB, isPrivate: false, nowMs: 1_100)
        // Put subA first so LiveA is index 0 and LiveB is index 1
        var ordered = storage.subscriptions()
        ordered.sort { $0.id < $1.id }
        storage.saveSubscriptions(ordered)

        let cfgBefore = storage.mergedConfig()
        XCTAssertEqual(cfgBefore.publicSupportedLives.map(\.name), ["A直播", "B直播"])
        let liveAId = PublicCatalogScopeGuard.liveSourceIdentity(cfgBefore.publicSupportedLives[0])
        let liveBId = PublicCatalogScopeGuard.liveSourceIdentity(cfgBefore.publicSupportedLives[1])
        let siteAKey = try XCTUnwrap(cfgBefore.publicAvailableSites.first(where: { $0.subscriptionId == subA.id })?.key)

        // Switch subA to PRIVATE -> now publicSupportedLives is [LiveB] so LiveB occupies index 0!
        var toggled = storage.subscriptions()
        toggled[toggled.firstIndex(where: { $0.id == subA.id })!].isPrivate = true
        storage.saveSubscriptions(toggled)
        let cfgAfter = storage.mergedConfig()
        XCTAssertEqual(cfgAfter.publicSupportedLives.map(\.name), ["B直播"])

        // 1) If user had LiveA (index 0) loaded, index 0 is STILL valid (now LiveB!), yet old LiveA channels MUST be cleared!
        let recA = PublicCatalogScopeGuard.reconcileLiveSourceSelection(
            previousLoadedIdentity: liveAId,
            currentSelectedIndex: 0,
            publicLives: cfgAfter.publicSupportedLives
        )
        XCTAssertTrue(recA.shouldClearLoadedGroups, "Loaded live source turning private must clear channels even when another public live takes index 0")
        XCTAssertNil(recA.nextLoadedIdentity)
        XCTAssertEqual(recA.nextIndex, 0)

        // 2) If user had LiveB (previously index 1) loaded, LiveB shifts cleanly to index 0 without clearing!
        let recB = PublicCatalogScopeGuard.reconcileLiveSourceSelection(
            previousLoadedIdentity: liveBId,
            currentSelectedIndex: 1,
            publicLives: cfgAfter.publicSupportedLives
        )
        XCTAssertFalse(recB.shouldClearLoadedGroups)
        XCTAssertEqual(recB.nextIndex, 0)
        XCTAssertEqual(recB.nextLoadedIdentity, liveBId)

        // 3) Slow in-flight Discover, Live TV & Search responses started before privacy toggle (epoch 1 -> epoch 2) MUST be dropped!
        XCTAssertFalse(
            PublicCatalogScopeGuard.canAcceptDiscoverResponse(
                siteKey: siteAKey,
                requestEpoch: 1,
                currentEpoch: 2,
                activeSiteKey: cfgAfter.publicAvailableSites.first?.key,
                config: cfgAfter
            )
        )
        XCTAssertFalse(
            PublicCatalogScopeGuard.canAcceptLiveResponse(
                sourceIdentity: liveAId,
                requestToken: 1,
                currentToken: 1,
                requestEpoch: 1,
                currentEpoch: 2,
                config: cfgAfter
            )
        )
        XCTAssertFalse(
            PublicCatalogScopeGuard.canAcceptSearchBatch(
                siteKey: siteAKey,
                requestToken: 1,
                currentToken: 1,
                requestEpoch: 1,
                currentEpoch: 2,
                config: cfgAfter
            )
        )
    }

    // MARK: - Item 3: Eliminate First-Create TOCTOU Overwrite Window + Keep If-Match + Pending Changes Status

    func testFinalItem3_WebDavRejectsUnsafeFirstCreatePreservesDeviceBUsesIfMatchAndReportsPendingChanges() async throws {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalDavA_\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalDavB_\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let storageA = TvStorageManager(cachesDirectory: dirA, keychain: InMemoryKeychainStore())
        let storageB = TvStorageManager(cachesDirectory: dirB, keychain: InMemoryKeychainStore())

        let rawA = #"{"sites":[{"key":"sa","name":"A站","type":1,"api":"https://sa.example/vod"}]}"#
        let rawB = #"{"sites":[{"key":"sb","name":"B站","type":1,"api":"https://sb.example/vod"}]}"#
        let (subA, _) = try storageA.upsertSubscription(id: "sub_fc_a", name: "A订阅", url: "https://sa.example/sub.json", rawContent: rawA, nowMs: 1_000)
        let (subB, _) = try storageB.upsertSubscription(id: "sub_fc_b", name: "B订阅", url: "https://sb.example/sub.json", rawContent: rawB, nowMs: 1_100)
        _ = storageA.toggleFavorite(site: CmsSite.canonicalScopedKey(rawKey: "sa", subscriptionId: subA.id), video: CmsVideo(id: "fav_a", title: "设备A片"), nowMs: 1_200)
        _ = storageB.toggleFavorite(site: CmsSite.canonicalScopedKey(rawKey: "sb", subscriptionId: subB.id), video: CmsVideo(id: "fav_b", title: "设备B抢先创建片"), nowMs: 1_300)

        let davCfg = WebDavConfig(
            url: "https://dav.example/remote.php/dav/files/user",
            username: "u",
            password: "synthetic-test-password",
            syncSubscriptions: true,
            syncHistory: true
        )
        try storageA.saveWebDavConfig(davCfg)
        try storageB.saveWebDavConfig(davCfg)

        let deviceBPayload = try WebDavSyncService(storage: storageB).exportSyncPayload(nowMs: 1_400)

        // Subtest A: Server rejects If-None-Match: * with HTTP 400, probe GET returns 404,
        // and Device B IMMEDIATELY creates the file right after that 404!
        let server = FinalMockWebDavServer(initialPayload: nil, initialEtag: nil)
        await server.configureFirstCreateRejectWithRace(
            rejectStatus: 400,
            deviceBPayloadAfterProbe404: deviceBPayload,
            deviceBEtag: "\"etag-dev-b\""
        )
        let serviceA = WebDavSyncService(storage: storageA, transport: FinalMockWebDavTransport(server: server))

        do {
            _ = try await serviceA.syncNow()
            XCTFail("Server rejecting atomic conditional creation after 404 probe must abort safely with retryable error instead of unconditional PUT")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重试"), "Error must provide retryable guidance: \(error.localizedDescription)")
        }

        let snapAfterAbort = await server.snapshot()
        XCTAssertEqual(snapAfterAbort.unconditionalPuts, 0, "Must NEVER issue an unconditional PUT after 404 probe")
        XCTAssertEqual(snapAfterAbort.payload, deviceBPayload, "Device B's freshly created remote file must remain 100% intact")

        // Subtest B: Retry on the SAME serviceA instance & SAME host -> GET now returns Device B + strong ETag `"etag-dev-b"` ->
        // MUST still send `If-Match: "etag-dev-b"` and merge BOTH Device A & Device B!
        let mergedSummary = try await serviceA.syncNow()
        XCTAssertFalse(mergedSummary.hasPendingLocalChanges)
        let snapAfterRetry = await server.snapshot()
        XCTAssertEqual(snapAfterRetry.unconditionalPuts, 0, "Host must NEVER have conditional writes disabled")
        XCTAssertEqual(snapAfterRetry.puts.last?.ifMatch, "\"etag-dev-b\"", "Subsequent write after reading strong ETag must still send If-Match")
        let remoteFinal = try XCTUnwrap(snapAfterRetry.payload)
        XCTAssertTrue(remoteFinal.contains("fav_a") && remoteFinal.contains("fav_b"))
        XCTAssertTrue(storageA.favorites().contains(where: { $0.id == "fav_a" }))
        XCTAssertTrue(storageA.favorites().contains(where: { $0.id == "fav_b" }))

        // Subtest C: Local mutation during FINAL PUT attempt (maxConflictRetries: 0) -> status MUST report "仍有改动待同步"!
        let nextPutIdx = snapAfterRetry.puts.count + 1
        await server.configurePauseOnPut(nextPutIdx)
        let finalSyncTask = Task {
            try await serviceA.syncNow(maxConflictRetries: 0)
        }
        try await server.waitUntilPutPaused()

        // Mutate locally while the LAST upload attempt is in flight
        _ = storageA.toggleFavorite(
            site: CmsSite.canonicalScopedKey(rawKey: "sa", subscriptionId: subA.id),
            video: CmsVideo(id: "fav_pending_final", title: "末次上传期间新增"),
            nowMs: Int64(Date().timeIntervalSince1970 * 1000) + 5_000
        )
        await server.resumePausedPut()

        let finalSummary = try await finalSyncTask.value
        XCTAssertTrue(finalSummary.hasPendingLocalChanges, "Mutation during final PUT must set hasPendingLocalChanges")
        let savedStatus = storageA.loadWebDavConfig().lastSyncStatus
        XCTAssertTrue(savedStatus.contains("仍有改动待同步"), "Expected status containing '仍有改动待同步', got: \(savedStatus)")
        XCTAssertTrue(storageA.favorites().contains(where: { $0.id == "fav_pending_final" }))
    }

    // MARK: - Item 4: Non-Numbered Episode Content Check + LocalHeaderProxyServer In-Flight Slow HLS Cancel

    @MainActor
    func testFinalItem4_NonNumberedEpisodeSwitchPromptsInsteadOfIndexMismatch() async throws {
        let site = CmsSite(key: "sub::s1::vod", name: "非编号测试站", type: 1, api: "https://nonnum.example/vod")
        let video = CmsVideo(
            id: "doc_1",
            title: "纪录片特别篇",
            lines: [
                CmsLine(
                    name: "线路A",
                    episodes: [
                        CmsEpisode(name: "正片", url: "https://cdn.example/a_main.m3u8"),
                        CmsEpisode(name: "片尾访谈", url: "https://cdn.example/a_interview.m3u8"),
                    ]
                ),
                CmsLine(
                    name: "线路B",
                    episodes: [
                        CmsEpisode(name: "制作花絮", url: "https://cdn.example/b_bts.m3u8"),
                    ]
                ),
                CmsLine(
                    name: "线路C",
                    episodes: [
                        CmsEpisode(name: "正片", url: "https://cdn.example/c_main.m3u8"),
                        CmsEpisode(name: "制作花絮", url: "https://cdn.example/c_bts.m3u8"),
                    ]
                ),
            ]
        )

        let engine = FinalMockPlaybackEngine()
        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 1, initialSeekMs: 0),
            engine: engine,
            resolver: { target in
                let ep = target.currentEpisode!
                return ResolvedPlayback(originalUrl: ep.url, playableUrl: URL(string: ep.url)!)
            },
            progressRecorder: { _, _, _ in }
        )

        // Playing "片尾访谈" (Line A, index 1) at 5 minutes (300_000 ms)
        coordinator.startInitialLoad()
        try await waitUntil { engine.loads.count == 1 }
        engine.markReady(positionMs: 300_000)
        let activeTok = engine.activeItemToken

        // Switch to Line B (only has "制作花絮") -> MUST prompt instead of carrying 5:00 to "制作花絮"!
        let outB = coordinator.switchVodLine(to: 1)
        guard case .missingEpisode(let infoB) = outB else {
            return XCTFail("Switching from '片尾访谈' to a line with only '制作花絮' must return .missingEpisode")
        }
        XCTAssertEqual(infoB.requestedEpisodeName, "片尾访谈")
        XCTAssertEqual(infoB.fallbackEpisodeName, "制作花絮")
        XCTAssertEqual(infoB.carrySeekMs, 300_000)
        XCTAssertEqual(engine.activeItemToken, activeTok, "Current playback must stay undisturbed until user chooses")

        // Switch to Line C (where "制作花絮" occupies the EXACT SAME index 1!) -> MUST STILL prompt!
        let outC = coordinator.switchVodLine(to: 2)
        guard case .missingEpisode(let infoC) = outC else {
            return XCTFail("Must NEVER silently jump from '片尾访谈' (idx 1) to '制作花絮' (idx 1) by array index")
        }
        XCTAssertEqual(infoC.requestedEpisodeName, "片尾访谈")
        XCTAssertEqual(infoC.fallbackEpisodeName, "制作花絮")
        XCTAssertEqual(infoC.carrySeekMs, 300_000)
        XCTAssertEqual(coordinator.activeLoaded?.lineIndex, 0)
        XCTAssertEqual(coordinator.activeLoaded?.episodeIndex, 1)

        // Single-feature main movie quality labels ("正片" <-> "蓝光") still match cleanly; bonus labels do not.
        XCTAssertEqual(
            PlaybackSessionCoordinator.matchingEpisodeIndex(
                for: CmsEpisode(name: "正片", url: "https://cdn.example/1.m3u8"),
                currentIndex: 0,
                in: [CmsEpisode(name: "蓝光", url: "https://cdn.example/2.m3u8")]
            ),
            0
        )
        XCTAssertNil(
            PlaybackSessionCoordinator.matchingEpisodeIndex(
                for: CmsEpisode(name: "片尾访谈", url: "https://cdn.example/1.m3u8"),
                currentIndex: 0,
                in: [CmsEpisode(name: "制作花絮", url: "https://cdn.example/2.m3u8")]
            )
        )
    }

    @MainActor
    func testFinalItem4_LocalHeaderProxyCancelsSlowHlsDownloadOnExitWhileOtherSessionContinues() async throws {
        let hlsServer = SlowHlsLoopbackServer()
        let hlsPort = try await hlsServer.start()
        defer { hlsServer.stop() }

        // Real LocalHeaderProxyServer using the default URLSession fetcher (verifying real URLSessionDataTask cancellation!)
        let headerProxy = LocalHeaderProxyServer()
        defer { headerProxy.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MarcoFinalHlsCancel_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = TvStorageManager(cachesDirectory: dir, keychain: InMemoryKeychainStore())
        let client = CmsClient()
        let site = CmsSite(key: "sub::s1::hls", name: "HLS测试站", type: 1, api: "http://127.0.0.1:\(hlsPort)/vod")

        let slowVideo = CmsVideo(
            id: "slow_hls",
            title: "慢分片HLS",
            lines: [
                CmsLine(
                    name: "HLS慢线",
                    episodes: [
                        CmsEpisode(
                            name: "正片",
                            url: "http://127.0.0.1:\(hlsPort)/slow_master.m3u8",
                            headers: ["Referer": "http://127.0.0.1:\(hlsPort)/"]
                        )
                    ]
                )
            ]
        )
        let fastVideo = CmsVideo(
            id: "fast_hls",
            title: "正常HLS",
            lines: [
                CmsLine(
                    name: "HLS快线",
                    episodes: [
                        CmsEpisode(
                            name: "正片",
                            url: "http://127.0.0.1:\(hlsPort)/fast_master.m3u8",
                            headers: ["Referer": "http://127.0.0.1:\(hlsPort)/"]
                        )
                    ]
                )
            ]
        )

        let resolvedBox = FinalTestBox<[String: ResolvedPlayback]>([:])
        func makeCoord(video: CmsVideo, engine: FinalMockPlaybackEngine) -> PlaybackSessionCoordinator {
            PlaybackSessionCoordinator(
                initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
                engine: engine,
                resolver: { target in
                    let resolved = try await client.resolvePlayback(
                        site: target.site,
                        lineName: target.currentLine!.name,
                        episode: target.currentEpisode!,
                        parses: [],
                        proxyServer: headerProxy,
                        storage: storage,
                        rangeProxyServer: nil,
                        isLiveStream: false
                    )
                    resolvedBox.withLock { $0[target.video.id] = resolved }
                    return resolved
                },
                progressRecorder: { _, _, _ in },
                resourceReleaser: { resolved in
                    if let hid = resolved.headerProxySessionId {
                        headerProxy.revokeSession(hid)
                    }
                }
            )
        }

        let engA = FinalMockPlaybackEngine()
        let engB = FinalMockPlaybackEngine()
        let coordA = makeCoord(video: slowVideo, engine: engA)
        let coordB = makeCoord(video: fastVideo, engine: engB)

        coordA.startInitialLoad()
        coordB.startInitialLoad()
        try await waitUntil { engA.loads.count == 1 && engB.loads.count == 1 }

        let resA = try XCTUnwrap(resolvedBox.withLock { $0["slow_hls"] })
        let resB = try XCTUnwrap(resolvedBox.withLock { $0["fast_hls"] })
        let sidA = try XCTUnwrap(resA.headerProxySessionId)
        let sidB = try XCTUnwrap(resB.headerProxySessionId)

        // Fetch rewritten playlists for both sessions
        let (m3u8DataA, _) = try await URLSession.shared.data(from: resA.playableUrl)
        let m3u8TextA = String(decoding: m3u8DataA, as: UTF8.self)
        let slowSegLine = try XCTUnwrap(m3u8TextA.components(separatedBy: .newlines).first(where: { $0.hasPrefix("http://127.0.0.1:") }))
        let slowSegUrl = try XCTUnwrap(URL(string: slowSegLine))

        let (m3u8DataB, _) = try await URLSession.shared.data(from: resB.playableUrl)
        let m3u8TextB = String(decoding: m3u8DataB, as: UTF8.self)
        let fastSegLine = try XCTUnwrap(m3u8TextB.components(separatedBy: .newlines).first(where: { $0.hasPrefix("http://127.0.0.1:") }))
        let fastSegUrl = try XCTUnwrap(URL(string: fastSegLine))

        // Start slow HLS segment download for Session A and wait until upstream is actively streaming
        let slowDownloadTask = Task { () -> Int? in
            do {
                let (_, resp) = try await URLSession.shared.data(from: slowSegUrl)
                return (resp as? HTTPURLResponse)?.statusCode
            } catch {
                return nil
            }
        }
        try await waitUntil {
            hlsServer.snapshot().slowStarted >= 1 && headerProxy.activeRequestCount(for: sidA) >= 1
        }

        // Exit Session A via normal PlaybackSessionCoordinator teardown -> MUST cancel in-flight slow upstream task!
        coordA.teardownAndPersist()
        await coordA.waitForPendingResourceReleases()

        try await waitUntil(timeoutNs: 4_000_000_000) {
            hlsServer.snapshot().slowCancelled >= 1 && headerProxy.activeRequestCount(for: sidA) == 0
        }
        let slowHttpStatus = await slowDownloadTask.value
        XCTAssertTrue(
            slowHttpStatus == nil || slowHttpStatus == 404,
            "Slow segment download must abort (or hit 404 if URLSession auto-retries GET after socket reset), got HTTP \(String(describing: slowHttpStatus))"
        )
        XCTAssertFalse(headerProxy.hasActiveSession(sidA))
        XCTAssertGreaterThanOrEqual(headerProxy.cancelledRequestCount(), 1)

        // Session B MUST continue playing cleanly with zero disruption!
        XCTAssertTrue(headerProxy.hasActiveSession(sidB))
        let (fastSegData, fastSegResp) = try await URLSession.shared.data(from: fastSegUrl)
        XCTAssertEqual((fastSegResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fastSegData, hlsServer.fastSegmentPayload)
        XCTAssertGreaterThanOrEqual(hlsServer.snapshot().fastServed, 1)

        coordB.teardownAndPersist()
        await coordB.waitForPendingResourceReleases()
        XCTAssertEqual(headerProxy.activeSessionCount(), 0)
    }

    // MARK: - Async Wait Helper

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
}

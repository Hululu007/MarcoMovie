// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import MarcoTVCore

// MARK: - Deterministic URLProtocol Stub for Netdisk & Redirect Tests

private final class LockedTestBox<Value>: @unchecked Sendable {
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

private final class StubNetdiskURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = LockedTestBox<Handler?>(nil)

    static func install(_ handler: @escaping Handler) {
        handlerBox.withLock { $0 = handler }
    }

    static func uninstall() {
        handlerBox.withLock { $0 = nil }
    }

    private static func snapshotHandler() -> Handler? {
        handlerBox.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.snapshotHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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

// MARK: - Loopback Byte-Range Upstream Test Server

private final class LoopbackRangeUpstreamServer: @unchecked Sendable {
    let payload: Data
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tests.upstream", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private var recordedRanges: [String] = []
    private var recordedAcceptEncodings: [String] = []
    private var delayGateChunks: Set<Int> = []
    private let chunkSize: Int

    init(payloadSize: Int = 524_288, chunkSize: Int = 65_536) {
        var bytes = [UInt8](repeating: 0, count: payloadSize)
        for i in 0..<payloadSize {
            bytes[i] = UInt8((i &* 31 &+ 7) & 0xFF)
        }
        self.payload = Data(bytes)
        self.chunkSize = chunkSize
    }

    deinit {
        stop()
    }

    func setSlowGate(forChunks chunks: Set<Int>) {
        lock.lock()
        delayGateChunks = chunks
        lock.unlock()
    }

    func snapshotObservedRequests() -> (ranges: [String], encodings: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (recordedRanges, recordedAcceptEncodings)
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
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

        setBoundListener(nwListener, port: assignedPort)
        return assignedPort
    }

    private func setBoundListener(_ nwListener: NWListener, port assignedPort: UInt16) {
        lock.lock()
        self.listener = nwListener
        self.port = assignedPort
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        port = 0
        delayGateChunks.removeAll()
        lock.unlock()
        active?.cancel()
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
            if let chunk = chunk { buf.append(chunk) }
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
        let acceptEnc = headers["accept-encoding"] ?? ""
        let gated: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if !rangeVal.isEmpty { recordedRanges.append(rangeVal) }
            if !acceptEnc.isEmpty { recordedAcceptEncodings.append(acceptEnc) }
            if rangeVal.hasPrefix("bytes="),
               let dash = rangeVal.firstIndex(of: "-"),
               let start = Int(rangeVal[rangeVal.index(rangeVal.startIndex, offsetBy: 6)..<dash])
            {
                let chunkIdx = start / chunkSize
                return delayGateChunks.contains(chunkIdx)
            }
            return false
        }()

        let respondBlock = { [weak self] in
            guard let self = self else {
                conn.cancel()
                return
            }
            let total = self.payload.count
            if rangeVal.hasPrefix("bytes="), let dash = rangeVal.firstIndex(of: "-") {
                let startStr = String(rangeVal[rangeVal.index(rangeVal.startIndex, offsetBy: 6)..<dash])
                let endStr = String(rangeVal[rangeVal.index(after: dash)...])
                if let s = Int(startStr), s >= 0, s < total {
                    let e = min(total - 1, Int(endStr) ?? (total - 1))
                    let slice = (method == "HEAD") ? Data() : self.payload.subdata(in: s..<(e + 1))
                    let hdrLines = [
                        "HTTP/1.1 206 Partial Content",
                        "Content-Type: video/x-matroska",
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

            let body = (method == "HEAD") ? Data() : self.payload
            let hdrLines = [
                "HTTP/1.1 200 OK",
                "Content-Type: video/x-matroska",
                "Accept-Ranges: bytes",
                "Content-Length: \(total)",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            var pkt = Data(hdrLines.utf8)
            pkt.append(body)
            conn.send(content: pkt, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        }

        if gated {
            queue.asyncAfter(deadline: .now() + 0.65, execute: respondBlock)
        } else {
            respondBlock()
        }
    }
}

// MARK: - Phase 2 Netdisk & Multi-Worker Range Proxy Test Suite

final class NetdiskAndRangeProxyTests: XCTestCase {

    override func tearDown() {
        StubNetdiskURLProtocol.uninstall()
        super.tearDown()
    }

    // MARK: - 1. NetdiskHeaderPolicy Redirect Domain Isolation

    func testHeaderPolicyRedirectIsolationAndIdentityEncoding() async throws {
        let origin = URL(string: "https://pan.quark.cn")!
        let policy = NetdiskHeaderPolicy(
            originUrl: origin,
            baseHeaders: [
                "Cookie": "__pus=secret_pus_1; __puus=secret_puus_2",
                "Authorization": "Bearer secret_quark_jwt",
                "Referer": "https://pan.quark.cn/\r\nX-Injected: bad",
                "Accept-Encoding": "gzip, br",
            ],
            cookieDomains: ["quark.cn"]
        )

        // Trusted provider subdomain -> preserves Cookie & Authorization, forces identity encoding
        let trustedSubdomain = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/download")!
        let trustedHeaders = policy.headers(for: trustedSubdomain, range: "bytes=0-1023")
        XCTAssertEqual(trustedHeaders["Cookie"], "__pus=secret_pus_1; __puus=secret_puus_2")
        XCTAssertEqual(trustedHeaders["Authorization"], "Bearer secret_quark_jwt")
        XCTAssertEqual(trustedHeaders["Accept-Encoding"], "identity")
        XCTAssertEqual(trustedHeaders["Range"], "bytes=0-1023")
        XCTAssertFalse((trustedHeaders["Referer"] ?? "").contains("\r"))
        XCTAssertFalse((trustedHeaders["Referer"] ?? "").contains("\n"))

        // Untrusted third-party CDN redirect -> strips Cookie & Authorization completely
        let untrustedCdn = URL(string: "https://cdn.example/4k_hdr_movie.mkv")!
        let cdnHeaders = policy.headers(for: untrustedCdn, range: "bytes=0-1023")
        XCTAssertNil(cdnHeaders["Cookie"])
        XCTAssertNil(cdnHeaders["Authorization"])
        XCTAssertEqual(cdnHeaders["Accept-Encoding"], "identity")
        XCTAssertEqual(cdnHeaders["Range"], "bytes=0-1023")

        // Downgrade to plain HTTP on trusted domain -> strips Cookie & Authorization
        let insecureDowngrade = URL(string: "http://drive.quark.cn/file.mkv")!
        let downgradeHeaders = policy.headers(for: insecureDowngrade)
        XCTAssertNil(downgradeHeaders["Cookie"])
        XCTAssertNil(downgradeHeaders["Authorization"])

        // End-to-end 2-hop redirect verification via NetdiskRangeProxyServer.fetchFollowingRedirects
        struct HopEntry {
            let host: String
            let cookie: String?
            let auth: String?
            let range: String?
        }
        let hopBox = LockedTestBox<[HopEntry]>([])

        StubNetdiskURLProtocol.install { req in
            let url = req.url!
            let host = url.host ?? ""
            hopBox.withLock { log in
                log.append(HopEntry(
                    host: host,
                    cookie: req.value(forHTTPHeaderField: "Cookie"),
                    auth: req.value(forHTTPHeaderField: "Authorization"),
                    range: req.value(forHTTPHeaderField: "Range")
                ))
            }

            if host == "drive-pc.quark.cn" {
                let r = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://drive.quark.cn/hop2"]
                )!
                return (r, Data())
            }
            if host == "drive.quark.cn" {
                let r = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://cdn.example/object/movie.mkv"]
                )!
                return (r, Data())
            }
            let r = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-3/100", "Content-Type": "video/x-matroska"]
            )!
            return (r, Data([0x1A, 0x45, 0xDF, 0xA3]))
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubNetdiskURLProtocol.self]
        let proxy = NetdiskRangeProxyServer(sessionConfiguration: cfg)
        defer { proxy.stop() }
        let testSession = URLSession(configuration: cfg)

        let resp = try await NetdiskRangeProxyServer.fetchFollowingRedirects(
            session: testSession,
            initialUrl: trustedSubdomain,
            method: "GET",
            range: "bytes=0-3",
            policy: policy
        )
        let hopLog = hopBox.withLock { $0 }
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.body, Data([0x1A, 0x45, 0xDF, 0xA3]))
        XCTAssertEqual(hopLog.count, 3)
        XCTAssertNotNil(hopLog[0].cookie)
        XCTAssertNotNil(hopLog[1].cookie)
        XCTAssertNil(hopLog[2].cookie, "Cross-domain CDN redirect hop must never receive Netdisk cookies")
        XCTAssertNil(hopLog[2].auth, "Cross-domain CDN redirect hop must never receive Authorization")
        XCTAssertEqual(hopLog[2].range, "bytes=0-3")
    }

    // MARK: - 2. NetdiskRangeProxyServer HEAD, 206 Multi-Chunk, 416 & Seek Preemption

    func testRangeProxyHeadMultiChunkStreaming416AndSeekPreemption() async throws {
        let upstream = LoopbackRangeUpstreamServer(payloadSize: 524_288, chunkSize: 65_536)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let proxy = NetdiskRangeProxyServer(
            workers: 4,
            chunkSize: 65_536,
            memoryLimit: 4 * 65_536
        )
        defer { proxy.stop() }

        let mediaUrl = URL(string: "http://127.0.0.1:\(upstreamPort)/4k_sample.mkv")!
        let policy = NetdiskHeaderPolicy(
            originUrl: mediaUrl,
            baseHeaders: ["Cookie": "__pus=local_loopback_ok"],
            cookieDomains: [],
            allowInsecureLoopbackCredentials: true
        )
        let (resourceId, proxyUrl) = try await proxy.registerStream(
            url: mediaUrl,
            policy: policy,
            contentTypeHint: "video/x-matroska"
        )

        // 1) Wrong capability token -> 403 Forbidden
        let wrongTokenUrl = URL(string: "http://127.0.0.1:\(proxy.port)/invalidtoken/\(resourceId)/media")!
        let (_, wrongResp) = try await URLSession.shared.data(from: wrongTokenUrl)
        XCTAssertEqual((wrongResp as? HTTPURLResponse)?.statusCode, 403)

        // 2) HEAD request -> 200 OK, Accept-Ranges: bytes, Content-Length: 524288
        var headReq = URLRequest(url: proxyUrl)
        headReq.httpMethod = "HEAD"
        let (headBody, headResp) = try await URLSession.shared.data(for: headReq)
        let headHttp = try XCTUnwrap(headResp as? HTTPURLResponse)
        XCTAssertEqual(headHttp.statusCode, 200)
        XCTAssertEqual(headHttp.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(headHttp.value(forHTTPHeaderField: "Content-Length"), "524288")
        XCTAssertTrue(headBody.isEmpty)

        // 3) Multi-chunk Range GET spanning 4 chunks (bytes=1000-200000) -> 206 Partial Content
        var rangeReq = URLRequest(url: proxyUrl)
        rangeReq.setValue("bytes=1000-200000", forHTTPHeaderField: "Range")
        let (sliceData, sliceResp) = try await URLSession.shared.data(for: rangeReq)
        let sliceHttp = try XCTUnwrap(sliceResp as? HTTPURLResponse)
        XCTAssertEqual(sliceHttp.statusCode, 206)
        XCTAssertEqual(sliceHttp.value(forHTTPHeaderField: "Content-Range"), "bytes 1000-200000/524288")
        XCTAssertEqual(sliceData.count, 199_001)
        XCTAssertEqual(sliceData, upstream.payload.subdata(in: 1000..<200_001))

        let observed = upstream.snapshotObservedRequests()
        XCTAssertTrue(observed.encodings.allSatisfy { $0 == "identity" })

        // 4) Invalid out-of-bounds Range -> 416 Range Not Satisfiable
        var invalidReq = URLRequest(url: proxyUrl)
        invalidReq.setValue("bytes=600000-700000", forHTTPHeaderField: "Range")
        let (_, invalidResp) = try await URLSession.shared.data(for: invalidReq)
        let invalidHttp = try XCTUnwrap(invalidResp as? HTTPURLResponse)
        XCTAssertEqual(invalidHttp.statusCode, 416)
        XCTAssertEqual(invalidHttp.value(forHTTPHeaderField: "Content-Range"), "bytes */524288")

        // 5) Seek preemption & memory ceiling check:
        // Slow down chunks 0...3, start reading at 0, then seek immediately to chunk 6 (bytes=393216-458751)
        upstream.setSlowGate(forChunks: [0, 1, 2, 3])
        let slowTask = Task<Data?, Never> {
            var r = URLRequest(url: proxyUrl)
            r.setValue("bytes=0-196607", forHTTPHeaderField: "Range")
            return try? await URLSession.shared.data(for: r).0
        }

        try await Task.sleep(nanoseconds: 90_000_000)

        var seekReq = URLRequest(url: proxyUrl)
        seekReq.setValue("bytes=393216-458751", forHTTPHeaderField: "Range")
        let (seekData, seekResp) = try await URLSession.shared.data(for: seekReq)
        let seekHttp = try XCTUnwrap(seekResp as? HTTPURLResponse)
        XCTAssertEqual(seekHttp.statusCode, 206)
        XCTAssertEqual(seekData.count, 65_536)
        XCTAssertEqual(seekData, upstream.payload.subdata(in: 393_216..<458_752))

        slowTask.cancel()
        _ = await slowTask.value

        let proxyMetrics = await proxy.metrics()
        XCTAssertGreaterThanOrEqual(proxyMetrics.preemptedWindowCount, 1)
        XCTAssertLessThanOrEqual(proxyMetrics.peakBufferedBytes, proxy.memoryLimit)
    }

    // MARK: - 3. NetdiskService 4-Provider QR Login & NetdiskShareResolver

    func testNetdiskQrStateMachineAndShareResolver() async throws {
        struct PollSteps {
            var quark = 0
            var baidu = 0
            var ali = 0
        }
        let stepBox = LockedTestBox(PollSteps())

        StubNetdiskURLProtocol.install { req in
            let url = req.url!
            let host = url.host ?? ""
            let path = url.path

            // --- Quark ---
            if host == "uop.quark.cn" && path.contains("getTokenForQrcodeLogin") {
                let json = #"{"status":2000000,"data":{"members":{"token":"qk_tok_001"}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "uop.quark.cn" && path.contains("getServiceTicketByQrcodeToken") {
                let step = stepBox.withLock { s -> Int in
                    s.quark += 1
                    return s.quark
                }
                let json: String
                if step == 1 {
                    json = #"{"status":50004001,"message":"waiting"}"#
                } else if step == 2 {
                    json = #"{"status":2000000,"data":{"members":{"service_ticket":"qk_st_99"}}}"#
                } else {
                    json = #"{"status":50004002,"message":"expired"}"#
                }
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "pan.quark.cn" && path == "/account/info" {
                let headers = [
                    "Set-Cookie": "__pus=qk_real_pus_token_123; Path=/; Secure, __puus=qk_real_puus_token_456; Path=/; HttpOnly",
                ]
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!, Data("{}".utf8))
            }

            // --- Quark Share Resolution ---
            if host == "drive-pc.quark.cn" && path.contains("/share/sharepage/token") {
                let json = #"{"status":200,"code":0,"data":{"stoken":"stoken_xyz"}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "drive-pc.quark.cn" && path.contains("/share/sharepage/detail") {
                let json = #"{"status":200,"code":0,"data":{"list":[{"fid":"fid_4k_01","share_fid_token":"sft_01","file_name":"Dune.Part.Two.2160p.4K.HDR.mkv","size":18000000000,"dir":false}]}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "drive-pc.quark.cn" && path.contains("/file/v2/play") {
                let json = #"{"status":200,"code":0,"data":{"video_list":[{"resolution":"super","video_info":{"url":"https://cdn.example/dune_1080p.mp4"}},{"resolution":"4k","video_info":{"url":"https://cdn.example/dune_4k_hdr.mkv"}}]}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }

            // --- UC ---
            if host == "api.open.uc.cn" && path.contains("getTokenForQrcodeLogin") {
                let json = #"{"status":2000000,"data":{"members":{"token":"uc_tok_002"}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "api.open.uc.cn" && path.contains("getServiceTicketByQrcodeToken") {
                let json = #"{"status":2000000,"data":{"members":{"service_ticket":"uc_st_88"}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "drive.uc.cn" && path == "/account/mobileinfo" {
                let json = #"{"status":200,"data":{"__pus":"uc_valid_pus_session_777"}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }

            // --- Baidu ---
            if host == "passport.baidu.com" && path == "/v2/api/getqrcode" {
                let jsonp = #"tangram_guid_1({"sign":"bd_sign_abc","errno":0})"#
                let headers = ["Set-Cookie": "BAIDUID=isolated_jar_01; Path=/"]
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!, Data(jsonp.utf8))
            }
            if host == "passport.baidu.com" && path == "/channel/unicast" {
                let step = stepBox.withLock { s -> Int in
                    s.baidu += 1
                    return s.baidu
                }
                let jsonp: String
                if step == 1 {
                    jsonp = #"tangram_guid_1({"errno":0,"channel_v":"{\"status\":1}"})"#
                } else {
                    jsonp = #"tangram_guid_1({"errno":0,"channel_v":"{\"status\":0,\"v\":\"bd_v_ticket_1\"}"})"#
                }
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(jsonp.utf8))
            }
            if host == "passport.baidu.com" && path == "/v3/login/main/qrbdusslogin" {
                let headers = ["Set-Cookie": "BDUSS=bduss_real_credential_888888; Path=/, STOKEN=stoken_real_999; Path=/"]
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!, Data("{}".utf8))
            }

            // --- AliyunDrive ---
            if host == "passport.aliyundrive.com" && path.contains("generate.do") {
                let json = #"{"content":{"data":{"codeContent":"https://www.aliyundrive.com/qr/ali_01","ck":"ali_ck_1","t":"1700000000"}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "passport.aliyundrive.com" && path.contains("query.do") {
                let step = stepBox.withLock { s -> Int in
                    s.ali += 1
                    return s.ali
                }
                if step == 1 {
                    let json = #"{"content":{"data":{"qrCodeStatus":"NEW"}}}"#
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
                }
                if step == 2 {
                    let json = #"{"content":{"data":{"qrCodeStatus":"SCANED"}}}"#
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
                }
                // Include non-UTF8 GBK bytes (0xC5 0x5C — trailing '\' in GBK!) inside nickName to verify safe decoding
                var rawBiz = Array(#"{"pds_login_result":{"nickName":""#.utf8)
                rawBiz.append(contentsOf: [0xC5, 0x5C])
                rawBiz.append(contentsOf: Array(#"","refreshToken":"ali_valid_refresh_token_1234567890abcdef"}}"#.utf8))
                let b64 = Data(rawBiz).base64EncodedString()
                let json = #"{"content":{"data":{"qrCodeStatus":"CONFIRMED","bizExt":"\#(b64)"}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }

            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubNetdiskURLProtocol.self]
        let service = NetdiskService(configuration: cfg)

        // 1) Quark lifecycle: waiting -> confirmed -> expired
        let qkSession = try await service.startQrSession(driveKey: "quark")
        XCTAssertTrue(qkSession.qrUrl.hasPrefix("https://su.quark.cn/4_eMHBJ"))
        let qkPoll1 = await service.pollQrSession(qkSession)
        XCTAssertEqual(qkPoll1.state, .waiting)
        let qkPoll2 = await service.pollQrSession(qkSession)
        XCTAssertEqual(qkPoll2.state, .confirmed)
        XCTAssertTrue(qkPoll2.credential.contains("__pus=qk_real_pus_token_123"))
        XCTAssertTrue(qkPoll2.credential.contains("__puus=qk_real_puus_token_456"))
        let qkPoll3 = await service.pollQrSession(qkSession)
        XCTAssertEqual(qkPoll3.state, .expired)

        // 2) UC lifecycle: confirmed
        let ucSession = try await service.startQrSession(driveKey: "uc")
        XCTAssertTrue(ucSession.qrUrl.hasPrefix("https://su.uc.cn/1_n0ZCv"))
        let ucPoll = await service.pollQrSession(ucSession)
        XCTAssertEqual(ucPoll.state, .confirmed)
        XCTAssertTrue(ucPoll.credential.contains("__pus=uc_valid_pus_session_777"))

        // 3) Baidu lifecycle: scanned -> confirmed (with isolated cookie jar)
        let bdSession = try await service.startQrSession(driveKey: "baidu")
        XCTAssertTrue(bdSession.qrUrl.hasPrefix("https://wappass.baidu.com/wp/?qrlogin"))
        XCTAssertEqual(bdSession.sessionCookies["BAIDUID"], "isolated_jar_01")
        let bdPoll1 = await service.pollQrSession(bdSession)
        XCTAssertEqual(bdPoll1.state, .scanned)
        let bdPoll2 = await service.pollQrSession(bdSession)
        XCTAssertEqual(bdPoll2.state, .confirmed)
        XCTAssertTrue(bdPoll2.credential.contains("BDUSS=bduss_real_credential_888888"))

        // 4) AliyunDrive lifecycle: waiting -> scanned -> confirmed (GBK-safe bizExt decode)
        let aliSession = try await service.startQrSession(driveKey: "ali")
        let aliPoll1 = await service.pollQrSession(aliSession)
        XCTAssertEqual(aliPoll1.state, .waiting)
        let aliPoll2 = await service.pollQrSession(aliSession)
        XCTAssertEqual(aliPoll2.state, .scanned)
        let aliPoll3 = await service.pollQrSession(aliSession)
        XCTAssertEqual(aliPoll3.state, .confirmed)
        XCTAssertEqual(aliPoll3.credential, "ali_token=ali_valid_refresh_token_1234567890abcdef")

        // 5) Quark Share -> 4K HDR Range Proxy Resolution
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoNetdiskShare_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())
        try storage.setNetdiskCredential(qkPoll2.credential, for: "quark")

        let proxy = NetdiskRangeProxyServer(workers: 6)
        defer { proxy.stop() }
        let resolver = NetdiskShareResolver(session: URLSession(configuration: cfg))

        let resolved = try await resolver.resolvePlayback(
            rawUrl: "https://pan.quark.cn/s/share888abc",
            lineName: "夸父4K原画",
            qualityPreference: "4k_hdr",
            playerKernel: "range_proxy",
            storage: storage,
            rangeProxy: proxy
        )
        XCTAssertTrue(resolved.isProxied)
        XCTAssertEqual(resolved.originalUrl, "https://cdn.example/dune_4k_hdr.mkv")
        XCTAssertEqual(resolved.resolutionBadge, "4K HDR")
        XCTAssertEqual(resolved.kernelLabel, "6 线程分片代理")
        XCTAssertTrue(resolved.playableUrl.absoluteString.hasPrefix("http://127.0.0.1:\(proxy.port)/"))
    }

    // MARK: - 4. Keychain Netdisk CRUD, Non-Export in BackupCodec & LAN /api/netdisk Push

    func testKeychainNetdiskCrudBackupIsolationAndLanPush() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoNetdiskStorage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())

        // Reject invalid, CRLF-injected, and placeholder tokens
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: ""))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: "qr_auth_fake_placeholder"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "quark", credential: "__pus=abc\r\nX-Evil: 1"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "baidu", credential: "bduss=lowercase_invalid"))
        XCTAssertFalse(NetdiskSessionValidator.isUsable(driveKey: "ali", credential: "ali_refresh_token_placeholder"))

        // Persist valid credentials for all 4 drives
        let qkSecret = "__pus=SECRET_QUARK_PUS_VALUE_9001; __puus=SECRET_QUARK_PUUS_VALUE_9002"
        let ucSecret = "__pus=SECRET_UC_PUS_VALUE_9003"
        let bdSecret = "BDUSS=SECRET_BAIDU_BDUSS_VALUE_9004; STOKEN=SECRET_STOKEN"
        let aliSecret = "SECRET_ALI_REFRESH_TOKEN_9005_ABCDEF123456"

        try storage.setNetdiskCredential(qkSecret, for: "quark")
        try storage.setNetdiskCredential(ucSecret, for: "uc")
        try storage.setNetdiskCredential(bdSecret, for: "baidu")
        try storage.setNetdiskCredential(aliSecret, for: "ali")

        XCTAssertEqual(Set(storage.loggedInNetdiskDrives()), ["quark", "uc", "baidu", "ali"])
        XCTAssertEqual(storage.netdiskCredential(for: "ali"), "ali_token=\(aliSecret)")

        // Verify BackupCodec NEVER exports any Netdisk credentials
        storage.updatePreferences {
            $0.netdiskQuality = "4k_hdr"
            $0.playerKernel = "range_proxy"
        }
        let exportedJson = try storage.exportBackupJson(exportedAt: 1_710_000_000_000)
        XCTAssertFalse(exportedJson.contains("SECRET_QUARK_PUS_VALUE_9001"))
        XCTAssertFalse(exportedJson.contains("SECRET_UC_PUS_VALUE_9003"))
        XCTAssertFalse(exportedJson.contains("SECRET_BAIDU_BDUSS_VALUE_9004"))
        XCTAssertFalse(exportedJson.contains("SECRET_ALI_REFRESH_TOKEN_9005"))

        let roundTrip = try BackupCodec.decodeBackupJson(exportedJson)
        XCTAssertEqual(roundTrip.preferences.netdiskQuality, "4k_hdr")
        XCTAssertEqual(roundTrip.preferences.playerKernel, "range_proxy")

        // Verify legacy PlaybackPreferences JSON without Phase 2 keys decodes cleanly with defaults
        let legacyPrefsJson = #"{"skipIntroSec":30,"skipOutroSec":45,"playSpeed":1.0,"autoNext":true,"episodesDescending":false,"repeatMode":"off","selectedSiteKey":"s1","preferredSiteKey":""}"#
        let decodedLegacy = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(legacyPrefsJson.utf8))
        XCTAssertEqual(decodedLegacy.skipIntroSec, 30)
        XCTAssertEqual(decodedLegacy.netdiskQuality, "auto")
        XCTAssertEqual(decodedLegacy.playerKernel, "range_proxy")

        // Verify LAN pairing-session bound POST /configure/<token>/netdisk push updates Keychain
        // and rejects unauthenticated /api/netdisk, invalid tokens, and expired sessions.
        let lanServer = LanConfigServer(storage: storage)
        let lanPort = try await lanServer.start(loopbackOnly: true)
        defer { lanServer.stop() }

        let consoleHtmlUrl = URL(string: lanServer.configureUrl(forHost: "127.0.0.1"))!
        let (consoleHtmlData, consoleHtmlResp) = try await URLSession.shared.data(from: consoleHtmlUrl)
        XCTAssertEqual((consoleHtmlResp as? HTTPURLResponse)?.statusCode, 200)
        let consoleHtml = String(decoding: consoleHtmlData, as: UTF8.self)
        XCTAssertTrue(consoleHtml.contains("'/netdisk'"))
        XCTAssertFalse(consoleHtml.contains("'/api/netdisk'"))

        // 1) Legacy unauthenticated /api/netdisk must be rejected with 404
        var unauthReq = URLRequest(url: URL(string: "http://127.0.0.1:\(lanPort)/api/netdisk")!)
        unauthReq.httpMethod = "POST"
        unauthReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "drive": "quark",
            "credential": "__pus=SHOULD_NEVER_WRITE_UNAUTH; __puus=NOPE",
        ])
        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(storage.netdiskCredential(for: "quark"), qkSecret)

        // 2) Wrong session token must be rejected with 404
        var wrongTokenReq = URLRequest(url: URL(string: "http://127.0.0.1:\(lanPort)/configure/0000000000000000/netdisk")!)
        wrongTokenReq.httpMethod = "POST"
        wrongTokenReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wrongTokenReq.httpBody = unauthReq.httpBody
        let (_, wrongTokenResp) = try await URLSession.shared.data(for: wrongTokenReq)
        XCTAssertEqual((wrongTokenResp as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(storage.netdiskCredential(for: "quark"), qkSecret)

        // 3) Valid active pairing session succeeds and persists synthetic credential
        let sessionNetdiskUrl = URL(string: lanServer.netdiskUrl(forHost: "127.0.0.1"))!
        var pushReq = URLRequest(url: sessionNetdiskUrl)
        pushReq.httpMethod = "POST"
        pushReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let pushedCookie = "__pus=LAN_PUSHED_QUARK_TOKEN_7788; __puus=LAN_PUSHED_PUUS_7799"
        pushReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "drive": "quark",
            "credential": pushedCookie,
        ])
        let (pushData, pushResp) = try await URLSession.shared.data(for: pushReq)
        XCTAssertEqual((pushResp as? HTTPURLResponse)?.statusCode, 200)
        let pushObj = try JSONSerialization.jsonObject(with: pushData) as? [String: Any]
        XCTAssertEqual(pushObj?["ok"] as? Bool, true)
        XCTAssertEqual(storage.netdiskCredential(for: "quark"), pushedCookie)

        // 4) Expired pairing session rejects credential push with 410 Gone
        let expiredServer = LanConfigServer(storage: storage, ttlSeconds: -1)
        _ = try await expiredServer.start(loopbackOnly: true)
        defer { expiredServer.stop() }
        var expiredReq = URLRequest(url: URL(string: expiredServer.netdiskUrl(forHost: "127.0.0.1"))!)
        expiredReq.httpMethod = "POST"
        expiredReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        expiredReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "drive": "quark",
            "credential": "__pus=EXPIRED_SESSION_REJECTED; __puus=NOPE",
        ])
        let (_, expiredResp) = try await URLSession.shared.data(for: expiredReq)
        XCTAssertEqual((expiredResp as? HTTPURLResponse)?.statusCode, 410)
        XCTAssertEqual(storage.netdiskCredential(for: "quark"), pushedCookie)

        // Verify resetAllData wipes all Netdisk Keychain credentials
        try storage.resetAllData()
        XCTAssertTrue(storage.loggedInNetdiskDrives().isEmpty)
        XCTAssertFalse(storage.isNetdiskLoggedIn("quark"))
        XCTAssertFalse(storage.isNetdiskLoggedIn("ali"))
    }

    // MARK: - 5. Ali Refresh Credential Isolation & HLS Sub-Playlist / Segment / Redirect Isolation

    func testAliRefreshTokenIsolationAndHlsProxyPerTargetMinimalHeaders() async throws {
        let syntheticRefresh = "SYNTH_ALI_REFRESH_998877665544332211"
        let syntheticAccess = "SYNTH_ALI_ACCESS_TOKEN_SHORT_LIVED"

        // 1) buildPolicy must never embed Ali refresh token into media headers
        let directPolicy = try XCTUnwrap(
            NetdiskShareResolver.buildPolicy(driveKey: "ali", credential: "ali_token=\(syntheticRefresh)")
        )
        let sameDomainDirectHeaders = directPolicy.headers(for: URL(string: "https://www.alipan.com/media/movie.mp4")!)
        let crossDomainDirectHeaders = directPolicy.headers(for: URL(string: "https://cdn.example/media/movie.mp4")!)
        for hdrMap in [sameDomainDirectHeaders, crossDomainDirectHeaders] {
            XCTAssertNil(hdrMap["X-Ali-Refresh-Token"])
            XCTAssertFalse(hdrMap.values.contains(where: { $0.contains(syntheticRefresh) }))
        }
        XCTAssertNil(crossDomainDirectHeaders["Origin"])
        XCTAssertNil(crossDomainDirectHeaders["Referer"])
        XCTAssertNil(crossDomainDirectHeaders["Authorization"])
        XCTAssertNil(crossDomainDirectHeaders["Cookie"])

        // 2) End-to-end Ali share resolution -> HLS proxy -> same-domain vs cross-domain sub-playlist, segment, key & redirect
        struct CapturedUpstreamCall {
            let url: String
            let headers: [String: String]
        }
        let apiCallsBox = LockedTestBox<[String]>([])
        let proxyCallsBox = LockedTestBox<[CapturedUpstreamCall]>([])

        StubNetdiskURLProtocol.install { req in
            let url = req.url!
            let path = url.path
            apiCallsBox.withLock { $0.append(url.absoluteString) }
            if path == "/v2/account/token" {
                let json = #"{"access_token":"\#(syntheticAccess)"}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if path == "/v2/share_link/get_share_token" {
                let json = #"{"share_token":"share_tok_demo"}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if path == "/adrive/v3/file/list_by_share" {
                let json = #"{"items":[{"file_id":"f_ali_1","name":"Demo.2160p.4K.mkv","category":"video"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if path == "/v2/file/get_share_link_video_preview_play_info" {
                let json = #"{"video_preview_play_info":{"live_transcoding_task_list":[{"template_id":"UHD","url":"https://www.alipan.com/hls/master.m3u8"}]}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let headerProxy = LocalHeaderProxyServer { url, _, headers in
            proxyCallsBox.withLock { $0.append(CapturedUpstreamCall(url: url.absoluteString, headers: headers)) }
            switch url.absoluteString {
            case "https://www.alipan.com/hls/master.m3u8":
                let manifest = """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=8000000
                https://www.alipan.com/hls/same_variant.m3u8
                #EXT-X-STREAM-INF:BANDWIDTH=4000000
                https://cdn.example/hls/cross_variant.m3u8
                """
                return ProxyUpstreamResponse(statusCode: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(manifest.utf8))
            case "https://www.alipan.com/hls/same_variant.m3u8":
                let sub = """
                #EXTM3U
                #EXT-X-KEY:METHOD=AES-128,URI="https://www.alipan.com/hls/same.key"
                https://www.alipan.com/hls/redirect_seg.ts
                """
                return ProxyUpstreamResponse(statusCode: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(sub.utf8))
            case "https://cdn.example/hls/cross_variant.m3u8":
                let sub = """
                #EXTM3U
                #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/hls/cross.key"
                https://cdn.example/hls/cross_seg.ts
                """
                return ProxyUpstreamResponse(statusCode: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(sub.utf8))
            case "https://www.alipan.com/hls/redirect_seg.ts":
                return ProxyUpstreamResponse(statusCode: 302, headers: ["Location": "https://cdn.example/hls/redirected_final.ts"], body: Data())
            default:
                return ProxyUpstreamResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: Data([0x47, 0x40]))
            }
        }
        defer { headerProxy.stop() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoAliIsolation_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())
        try storage.setNetdiskCredential(syntheticRefresh, for: "ali")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubNetdiskURLProtocol.self]
        let resolver = NetdiskShareResolver(session: URLSession(configuration: cfg))

        let resolved = try await resolver.resolvePlayback(
            rawUrl: "https://www.alipan.com/s/shareDemo123",
            lineName: "阿狸4K",
            qualityPreference: "4k_hdr",
            playerKernel: "range_proxy",
            storage: storage,
            rangeProxy: nil,
            headerProxy: headerProxy
        )
        XCTAssertTrue(resolved.isProxied)

        // Fetch rewritten master playlist and follow every rewritten sub-playlist, key, segment & redirect
        let (masterData, _) = try await URLSession.shared.data(from: resolved.playableUrl)
        let masterText = String(decoding: masterData, as: UTF8.self)
        let variantUrls = masterText
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("http://127.0.0.1:") }
            .compactMap(URL.init(string:))
        XCTAssertEqual(variantUrls.count, 2)

        for vUrl in variantUrls {
            let (subData, _) = try await URLSession.shared.data(from: vUrl)
            let subText = String(decoding: subData, as: UTF8.self)
            for line in subText.components(separatedBy: .newlines) {
                if let range = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                    let quoted = String(line[range])
                    let inner = quoted.replacingOccurrences(of: "URI=\"", with: "").replacingOccurrences(of: "\"", with: "")
                    if let keyUrl = URL(string: inner) {
                        _ = try await URLSession.shared.data(from: keyUrl)
                    }
                } else if line.hasPrefix("http://127.0.0.1:"), let segUrl = URL(string: line) {
                    _ = try await URLSession.shared.data(from: segUrl)
                }
            }
        }

        let captured = proxyCallsBox.withLock { $0 }
        func callFor(_ urlStr: String) throws -> CapturedUpstreamCall {
            try XCTUnwrap(captured.first(where: { $0.url == urlStr }), "Expected request to \(urlStr)")
        }

        // Refresh token NEVER appears on ANY media/HLS/redirect request
        for call in captured {
            XCTAssertNil(call.headers["X-Ali-Refresh-Token"], "Refresh token header leaked to \(call.url)")
            XCTAssertFalse(call.headers.values.contains(where: { $0.contains(syntheticRefresh) }), "Refresh token value leaked to \(call.url)")
        }

        // Same-domain trusted requests carry short-lived Bearer access token
        XCTAssertEqual(try callFor("https://www.alipan.com/hls/master.m3u8").headers["Authorization"], "Bearer \(syntheticAccess)")
        XCTAssertEqual(try callFor("https://www.alipan.com/hls/same_variant.m3u8").headers["Authorization"], "Bearer \(syntheticAccess)")
        XCTAssertEqual(try callFor("https://www.alipan.com/hls/same.key").headers["Authorization"], "Bearer \(syntheticAccess)")
        XCTAssertEqual(try callFor("https://www.alipan.com/hls/redirect_seg.ts").headers["Authorization"], "Bearer \(syntheticAccess)")

        // Cross-domain sub-playlist, key, segment, and 302 redirect destination strip ALL credentials & Origin/Referer
        for crossUrl in [
            "https://cdn.example/hls/cross_variant.m3u8",
            "https://cdn.example/hls/cross.key",
            "https://cdn.example/hls/cross_seg.ts",
            "https://cdn.example/hls/redirected_final.ts",
        ] {
            let hdrs = try callFor(crossUrl).headers
            XCTAssertNil(hdrs["Authorization"], "Authorization leaked cross-domain to \(crossUrl)")
            XCTAssertNil(hdrs["Cookie"], "Cookie leaked cross-domain to \(crossUrl)")
            XCTAssertNil(hdrs["Origin"], "Origin leaked cross-domain to \(crossUrl)")
            XCTAssertNil(hdrs["Referer"], "Referer leaked cross-domain to \(crossUrl)")
            XCTAssertEqual(hdrs["Accept-Encoding"], "identity")
            XCTAssertNotNil(hdrs["User-Agent"])
        }
    }

    // MARK: - 6. Large-File HTTP 200 (Range-Ignoring) Bounded Streaming, Seeking, Exit & Peak RSS

    func testLargeFileRangeIgnoring200BoundedStreamingSeekExitAndPeakMemory() async throws {
        let virtualFileSize: Int64 = 64 * 1024 * 1024 // 64 MiB virtual file (never allocated in full)
        let upstream = LoopbackLargeNonRangeUpstreamServer(virtualSize: virtualFileSize)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let proxy = NetdiskRangeProxyServer(
            workers: 4,
            chunkSize: 65_536,
            memoryLimit: 4 * 65_536,
            maxNonRangeSkipBytes: 4 * 1024 * 1024
        )
        defer { proxy.stop() }

        let mediaUrl = URL(string: "http://127.0.0.1:\(upstreamPort)/large_64mb_movie.mp4")!
        let policy = NetdiskHeaderPolicy(
            originUrl: mediaUrl,
            baseHeaders: [
                "Cookie": "__pus=trusted_large_200_cookie",
                "Authorization": "Bearer trusted_large_200_token",
            ],
            cookieDomains: [],
            allowInsecureLoopbackCredentials: true
        )
        let (_, proxyUrl) = try await proxy.registerStream(
            url: mediaUrl,
            policy: policy,
            contentTypeHint: "video/mp4"
        )

        let rssBefore = Self.currentResidentMemoryBytes()
        var rssPeak = rssBefore

        // 1) First play: request initial 256 KiB slice against Range-ignoring 64 MiB HTTP 200 upstream
        var firstReq = URLRequest(url: proxyUrl)
        firstReq.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        let (firstData, firstResp) = try await URLSession.shared.data(for: firstReq)
        let firstHttp = try XCTUnwrap(firstResp as? HTTPURLResponse)
        XCTAssertEqual(firstHttp.statusCode, 206)
        XCTAssertEqual(firstHttp.value(forHTTPHeaderField: "Accept-Ranges"), "none")
        XCTAssertEqual(firstHttp.value(forHTTPHeaderField: "Content-Range"), "bytes 0-262143/\(virtualFileSize)")
        XCTAssertEqual(firstData.count, 262_144)
        XCTAssertEqual(firstData, LoopbackLargeNonRangeUpstreamServer.expectedBytes(offset: 0, length: 262_144))

        rssPeak = max(rssPeak, Self.currentResidentMemoryBytes())
        let metricsAfterFirst = await proxy.metrics()
        XCTAssertLessThanOrEqual(metricsAfterFirst.peakBufferedBytes, proxy.memoryLimit)
        XCTAssertLessThan(metricsAfterFirst.upstreamBytesRead, 4 * 1024 * 1024, "First play must abort upstream early instead of buffering 64 MiB")

        let initialServerStats = upstream.snapshotStats()
        XCTAssertTrue(initialServerStats.recordedCookies.contains("__pus=trusted_large_200_cookie"))

        // 2) Continuous seeking across offsets (1 MiB, then 2 MiB) + overlapping seek preemption
        for seekOffset in [Int64(1_048_576), Int64(2_097_152)] {
            var seekReq = URLRequest(url: proxyUrl)
            seekReq.setValue("bytes=\(seekOffset)-\(seekOffset + 65_535)", forHTTPHeaderField: "Range")
            let (seekData, seekResp) = try await URLSession.shared.data(for: seekReq)
            let seekHttp = try XCTUnwrap(seekResp as? HTTPURLResponse)
            XCTAssertEqual(seekHttp.statusCode, 206)
            XCTAssertEqual(seekData.count, 65_536)
            XCTAssertEqual(seekData, LoopbackLargeNonRangeUpstreamServer.expectedBytes(offset: seekOffset, length: 65_536))
            rssPeak = max(rssPeak, Self.currentResidentMemoryBytes())
        }

        // Overlapping slow stream preempted by a new seek request
        upstream.setChunkDelayMs(6)
        let slowSession = URLSession(configuration: .ephemeral)
        defer { slowSession.invalidateAndCancel() }
        let slowStreamTask = Task<Int, Never> {
            do {
                let (bytes, _) = try await slowSession.bytes(for: URLRequest(url: proxyUrl))
                var count = 0
                for try await _ in bytes {
                    count += 1
                    if count >= 4 * 1024 * 1024 { break }
                }
                return count
            } catch {
                return 0
            }
        }
        try await Task.sleep(nanoseconds: 90_000_000)

        upstream.setChunkDelayMs(0)
        var preemptSeekReq = URLRequest(url: proxyUrl)
        preemptSeekReq.setValue("bytes=524288-589823", forHTTPHeaderField: "Range")
        let (preemptData, preemptResp) = try await URLSession.shared.data(for: preemptSeekReq)
        let preemptHttp = try XCTUnwrap(preemptResp as? HTTPURLResponse)
        XCTAssertEqual(preemptHttp.statusCode, 206)
        XCTAssertEqual(preemptData, LoopbackLargeNonRangeUpstreamServer.expectedBytes(offset: 524_288, length: 65_536))
        slowStreamTask.cancel()
        _ = await slowStreamTask.value
        rssPeak = max(rssPeak, Self.currentResidentMemoryBytes())

        // 3) Exit / revoke mid-stream on unbounded 64 MiB HTTP 200 GET
        upstream.setChunkDelayMs(4)
        let exitSession = URLSession(configuration: .ephemeral)
        defer { exitSession.invalidateAndCancel() }
        let (exitBytes, exitResp) = try await exitSession.bytes(for: URLRequest(url: proxyUrl))
        XCTAssertEqual((exitResp as? HTTPURLResponse)?.statusCode, 200)
        var readOnExit = 0
        var exitIterator = exitBytes.makeAsyncIterator()
        while readOnExit < 131_072, let _ = try await exitIterator.next() {
            readOnExit += 1
        }
        XCTAssertEqual(readOnExit, 131_072)

        // Simulate player exit: cancel client socket and revoke proxy stream
        exitBytes.task.cancel()
        await proxy.revokeAll()
        try await Task.sleep(nanoseconds: 120_000_000)
        rssPeak = max(rssPeak, Self.currentResidentMemoryBytes())

        let finalMetrics = await proxy.metrics()
        let finalServerStats = upstream.snapshotStats()

        let rssBeforeMB = Double(rssBefore) / 1_048_576.0
        let rssPeakMB = Double(rssPeak) / 1_048_576.0
        let rssDeltaMB = Double(Int64(rssPeak) - Int64(rssBefore)) / 1_048_576.0
        print(
            String(
                format: "[Item6-Metrics] virtualFileMB=64.0 rssBeforeMB=%.2f rssPeakMB=%.2f rssDeltaMB=%.2f proxyPeakBufferedBytes=%d currentBufferedBytes=%d upstreamBytesRead=%lld serverBytesWritten=%lld cancelledUpstreamRequests=%d preemptedWindows=%d serverAbortedConns=%d",
                rssBeforeMB,
                rssPeakMB,
                rssDeltaMB,
                finalMetrics.peakBufferedBytes,
                finalMetrics.currentBufferedBytes,
                finalMetrics.upstreamBytesRead,
                finalServerStats.totalBytesWritten,
                finalMetrics.cancelledUpstreamRequests,
                finalMetrics.preemptedWindowCount,
                finalServerStats.abortedConnections
            )
        )

        XCTAssertEqual(finalMetrics.currentBufferedBytes, 0, "All buffered memory reservations must be released after exit")
        XCTAssertLessThanOrEqual(finalMetrics.peakBufferedBytes, proxy.memoryLimit)
        XCTAssertGreaterThanOrEqual(finalMetrics.preemptedWindowCount, 1)
        XCTAssertGreaterThanOrEqual(finalMetrics.cancelledUpstreamRequests, 2)
        XCTAssertGreaterThanOrEqual(finalServerStats.abortedConnections, 1)
        XCTAssertLessThan(finalMetrics.upstreamBytesRead, 16 * 1024 * 1024, "Total upstream bytes read across all scenarios must remain well below 64 MiB")
        XCTAssertLessThan(finalServerStats.totalBytesWritten, 24 * 1024 * 1024, "Upstream server must stop sending promptly when proxy cancels")
        XCTAssertLessThan(Int64(rssPeak) - Int64(rssBefore), 48 * 1024 * 1024, "Process RSS must never absorb the 64 MiB virtual media file")

        // 4) Cross-origin 302 redirect on Range-ignoring 200 upstream preserves auth on origin hop and strips on target hop
        let cdnTarget = LoopbackLargeNonRangeUpstreamServer(virtualSize: 2 * 1024 * 1024)
        let cdnPort = try await cdnTarget.start()
        defer { cdnTarget.stop() }
        let redirectTargetUrl = "http://127.0.0.1:\(cdnPort)/cdn_non_range.mp4"
        upstream.setRedirectLocation(redirectTargetUrl)
        upstream.setChunkDelayMs(0)

        let originRedirectUrl = URL(string: "http://127.0.0.1:\(upstreamPort)/redirect_movie.mp4")!
        let redirectPolicy = NetdiskHeaderPolicy(
            originUrl: originRedirectUrl,
            baseHeaders: [
                "Cookie": "__pus=origin_only_secret",
                "Authorization": "Bearer origin_only_bearer",
            ],
            cookieDomains: [],
            allowInsecureLoopbackCredentials: true
        )
        let (_, redirectProxyUrl) = try await proxy.registerStream(
            url: originRedirectUrl,
            policy: redirectPolicy,
            contentTypeHint: "video/mp4"
        )
        var redirReq = URLRequest(url: redirectProxyUrl)
        redirReq.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (redirData, redirResp) = try await URLSession.shared.data(for: redirReq)
        XCTAssertEqual((redirResp as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(redirData, LoopbackLargeNonRangeUpstreamServer.expectedBytes(offset: 0, length: 65_536))

        let originStatsAfterRedir = upstream.snapshotStats()
        let cdnStatsAfterRedir = cdnTarget.snapshotStats()
        XCTAssertTrue(originStatsAfterRedir.recordedCookies.contains("__pus=origin_only_secret"))
        XCTAssertTrue(cdnStatsAfterRedir.recordedCookies.isEmpty, "Cross-origin redirect hop must NOT receive Cookie")
        XCTAssertTrue(cdnStatsAfterRedir.recordedAuthorizations.isEmpty, "Cross-origin redirect hop must NOT receive Authorization")
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        #else
        return 0
        #endif
    }
}

// MARK: - Controlled Virtual Large-File HTTP 200 (Range-Ignoring) Upstream Server

private final class LoopbackLargeNonRangeUpstreamServer: @unchecked Sendable {
    struct Stats {
        let requestCount: Int
        let totalBytesWritten: Int64
        let abortedConnections: Int
        let recordedCookies: [String]
        let recordedAuthorizations: [String]
    }

    let virtualSize: Int64
    private let streamBlockSize: Int
    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tests.large200", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private var requestCount: Int = 0
    private var totalBytesWritten: Int64 = 0
    private var abortedConnections: Int = 0
    private var recordedCookies: [String] = []
    private var recordedAuthorizations: [String] = []
    private var chunkDelayMs: Int = 0
    private var redirectLocation: String?

    init(virtualSize: Int64, streamBlockSize: Int = 65_536) {
        self.virtualSize = virtualSize
        self.streamBlockSize = streamBlockSize
    }

    deinit {
        stop()
    }

    static func expectedBytes(offset: Int64, length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        for idx in 0..<length {
            let pos = offset + Int64(idx)
            bytes[idx] = UInt8((pos &* 131 &+ 17) & 0xFF)
        }
        return Data(bytes)
    }

    func setChunkDelayMs(_ ms: Int) {
        lock.lock()
        chunkDelayMs = max(0, ms)
        lock.unlock()
    }

    func setRedirectLocation(_ location: String?) {
        lock.lock()
        redirectLocation = location
        lock.unlock()
    }

    func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(
            requestCount: requestCount,
            totalBytesWritten: totalBytesWritten,
            abortedConnections: abortedConnections,
            recordedCookies: recordedCookies,
            recordedAuthorizations: recordedAuthorizations
        )
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
        self.listener = nwListener
        self.port = boundPort
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

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn: conn, acc: Data())
    }

    private func readRequest(conn: NWConnection, acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, isComplete, err in
            guard let self = self, err == nil else {
                conn.cancel()
                return
            }
            var buf = acc
            if let chunk = chunk { buf.append(chunk) }
            if let sep = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let hdr = String(decoding: buf.subdata(in: 0..<sep.lowerBound), as: UTF8.self)
                self.respond(headerText: hdr, conn: conn)
            } else if isComplete {
                conn.cancel()
            } else {
                self.readRequest(conn: conn, acc: buf)
            }
        }
    }

    private func respond(headerText: String, conn: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        let reqParts = (lines.first ?? "").split(separator: " ").map(String.init)
        let method = reqParts.first?.uppercased() ?? "GET"
        let path = reqParts.count > 1 ? reqParts[1] : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let redirTarget: String? = {
            lock.lock()
            defer { lock.unlock() }
            requestCount += 1
            if let c = headers["cookie"], !c.isEmpty { recordedCookies.append(c) }
            if let a = headers["authorization"], !a.isEmpty { recordedAuthorizations.append(a) }
            return path.contains("redirect") ? redirectLocation : nil
        }()

        if let location = redirTarget {
            let hdr = [
                "HTTP/1.1 302 Found",
                "Location: \(location)",
                "Content-Length: 0",
                "Connection: close",
                "",
                "",
            ].joined(separator: "\r\n")
            conn.send(content: Data(hdr.utf8), isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // Deliberately IGNORE any `Range` header and respond with HTTP 200 OK for the entire virtual file.
        let hdr = [
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp4",
            "Content-Length: \(virtualSize)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        if method == "HEAD" {
            conn.send(content: Data(hdr.utf8), isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        conn.send(content: Data(hdr.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self else {
                conn.cancel()
                return
            }
            if err != nil {
                self.recordAbort()
                conn.cancel()
                return
            }
            self.sendNextBlock(conn: conn, offset: 0)
        })
    }

    private func sendNextBlock(conn: NWConnection, offset: Int64) {
        guard offset < virtualSize else {
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }
        let len = Int(min(Int64(streamBlockSize), virtualSize - offset))
        let block = Self.expectedBytes(offset: offset, length: len)
        let delayMs: Int = {
            lock.lock()
            defer { lock.unlock() }
            return chunkDelayMs
        }()

        let dispatchSend = { [weak self] in
            guard let self = self else {
                conn.cancel()
                return
            }
            conn.send(content: block, completion: .contentProcessed { [weak self] err in
                guard let self = self else {
                    conn.cancel()
                    return
                }
                if err != nil {
                    self.recordAbort()
                    conn.cancel()
                    return
                }
                self.lock.lock()
                self.totalBytesWritten += Int64(len)
                self.lock.unlock()
                self.sendNextBlock(conn: conn, offset: offset + Int64(len))
            })
        }

        if delayMs > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: dispatchSend)
        } else {
            dispatchSend()
        }
    }

    private func recordAbort() {
        lock.lock()
        abortedConnections += 1
        lock.unlock()
    }
}

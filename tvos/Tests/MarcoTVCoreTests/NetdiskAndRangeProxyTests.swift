// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network
import XCTest
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

        // Verify LAN POST /api/netdisk push updates Keychain
        let lanServer = LanConfigServer(storage: storage)
        let lanPort = try await lanServer.start(loopbackOnly: true)
        defer { lanServer.stop() }

        let apiNetdiskUrl = URL(string: "http://127.0.0.1:\(lanPort)/api/netdisk")!
        var pushReq = URLRequest(url: apiNetdiskUrl)
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

        // Verify resetAllData wipes all Netdisk Keychain credentials
        try storage.resetAllData()
        XCTAssertTrue(storage.loggedInNetdiskDrives().isEmpty)
        XCTAssertFalse(storage.isNetdiskLoggedIn("quark"))
        XCTAssertFalse(storage.isNetdiskLoggedIn("ali"))
    }
}

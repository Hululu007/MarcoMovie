// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

public struct ProxyUpstreamResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public typealias ProxyUpstreamFetcher = @Sendable (
    _ url: URL,
    _ method: String,
    _ headers: [String: String]
) async throws -> ProxyUpstreamResponse

private final class LocalHeaderNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Intercept every redirect so LocalHeaderProxyServer recomputes minimal per-target headers.
        completionHandler(nil)
    }
}

private final class CancellableDataTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func attach(_ dataTask: URLSessionDataTask) {
        lock.lock()
        let shouldCancel = cancelled
        task = dataTask
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        } else {
            dataTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}

/// Loopback-only (`127.0.0.1`) HTTP proxy for tvOS `AVPlayer` that evaluates per-target
/// `NetdiskHeaderPolicy` isolation across HLS manifests, sub-playlists, segments, and redirects.
public final class LocalHeaderProxyServer: @unchecked Sendable {
    private static let maxRedirects = 8

    private struct StreamSession: Sendable {
        let id: String
        let rootUrl: URL
        let policy: NetdiskHeaderPolicy
        let createdAt: Date
    }

    private struct ActiveRequestHandle {
        let cancel: @Sendable () -> Void
    }

    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tv.header-proxy")
    private let lock = NSLock()
    private var sessions: [String: StreamSession] = [:]
    private var activeRequestsBySession: [String: [UUID: ActiveRequestHandle]] = [:]
    private var cancelledRequestsTotal: Int = 0
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0
    private let redirectDelegate: LocalHeaderNoRedirectDelegate
    private let urlSession: URLSession?
    private let upstreamFetcher: ProxyUpstreamFetcher

    public init(upstreamFetcher: ProxyUpstreamFetcher? = nil) {
        let delegate = LocalHeaderNoRedirectDelegate()
        self.redirectDelegate = delegate
        if let custom = upstreamFetcher {
            self.urlSession = nil
            self.upstreamFetcher = custom
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 60
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            self.urlSession = session
            self.upstreamFetcher = { url, method, headers in
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.httpMethod = method
                request.httpShouldHandleCookies = false
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
                let state = CancellableDataTaskState()
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let dataTask = session.dataTask(with: request) { data, resp, error in
                            if let error {
                                let nsErr = error as NSError
                                if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                                    continuation.resume(throwing: CancellationError())
                                } else {
                                    continuation.resume(throwing: error)
                                }
                                return
                            }
                            let httpResp = resp as? HTTPURLResponse
                            var respHeaders: [String: String] = [:]
                            if let all = httpResp?.allHeaderFields {
                                for (rk, rv) in all {
                                    respHeaders[String(describing: rk)] = String(describing: rv)
                                }
                            }
                            continuation.resume(
                                returning: ProxyUpstreamResponse(
                                    statusCode: httpResp?.statusCode ?? 200,
                                    headers: respHeaders,
                                    body: data ?? Data()
                                )
                            )
                        }
                        state.attach(dataTask)
                    }
                } onCancel: {
                    state.cancel()
                }
            }
        }
    }

    deinit {
        stop()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func startIfNeeded() async throws -> UInt16 {
        if let existingPort = withLock({ (listener != nil && port > 0) ? port : nil }) {
            return existingPort
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumeLock = NSLock()
            var resumed = false
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let p = nwListener.port?.rawValue, p > 0 {
                        continuation.resume(returning: p)
                    } else {
                        continuation.resume(throwing: MarcoError.networkFailure("本地代理端口分配失败"))
                    }
                case .failed(let err):
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: MarcoError.networkFailure("本地代理启动失败：\(err)"))
                case .cancelled:
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: MarcoError.networkFailure("本地代理已取消"))
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        withLock {
            self.listener = nwListener
            self.port = boundPort
        }
        return boundPort
    }

    public func stop() {
        let (current, allHandles) = withLock { () -> (NWListener?, [ActiveRequestHandle]) in
            let existing = listener
            listener = nil
            port = 0
            sessions.removeAll()
            let handles = activeRequestsBySession.values.flatMap(\.values)
            activeRequestsBySession.removeAll()
            return (existing, handles)
        }
        current?.cancel()
        for h in allHandles {
            h.cancel()
        }
        urlSession?.invalidateAndCancel()
    }

    public func revokeSession(_ sessionId: String) {
        let handles = withLock { () -> [ActiveRequestHandle] in
            _ = sessions.removeValue(forKey: sessionId)
            let removed = activeRequestsBySession.removeValue(forKey: sessionId)
            if let removed, !removed.isEmpty {
                cancelledRequestsTotal += removed.count
                return Array(removed.values)
            }
            return []
        }
        for h in handles {
            h.cancel()
        }
    }

    public func activeSessionCount() -> Int {
        withLock { sessions.count }
    }

    public func hasActiveSession(_ sessionId: String) -> Bool {
        withLock { sessions[sessionId] != nil }
    }

    public func activeRequestCount(for sessionId: String? = nil) -> Int {
        withLock {
            if let sid = sessionId {
                return activeRequestsBySession[sid]?.count ?? 0
            }
            return activeRequestsBySession.values.reduce(0) { $0 + $1.count }
        }
    }

    public func cancelledRequestCount() -> Int {
        withLock { cancelledRequestsTotal }
    }

    /// Registers an upstream media URL + origin-bound `NetdiskHeaderPolicy` and returns both the
    /// revocable `sessionId` and loopback URL playable by `AVPlayer`.
    public func registerStreamWithId(
        url: URL,
        policy: NetdiskHeaderPolicy
    ) async throws -> (sessionId: String, proxyUrl: URL) {
        let activePort = try await startIfNeeded()
        var tokenBytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<tokenBytes.count {
            tokenBytes[i] = UInt8.random(in: 0...255)
        }
        let sessionId = tokenBytes.map { String(format: "%02x", $0) }.joined()
        let session = StreamSession(id: sessionId, rootUrl: url, policy: policy, createdAt: Date())

        let evictedHandles = withLock { () -> [ActiveRequestHandle] in
            var evicted: [ActiveRequestHandle] = []
            if sessions.count >= 64,
               let oldest = sessions.min(by: { $0.value.createdAt < $1.value.createdAt })?.key
            {
                sessions.removeValue(forKey: oldest)
                if let removed = activeRequestsBySession.removeValue(forKey: oldest) {
                    evicted = Array(removed.values)
                }
            }
            sessions[sessionId] = session
            return evicted
        }
        for h in evictedHandles {
            h.cancel()
        }

        let ext = url.pathExtension.lowercased()
        let leaf = (ext == "mp4" || ext == "mkv" || ext == "mov" || ext == "ts") ? "stream.\(ext)" : "master.m3u8"
        guard let proxyUrl = URL(string: "http://127.0.0.1:\(activePort)/proxy/\(sessionId)/\(leaf)") else {
            throw MarcoError.networkFailure("无法构造本地代理播放地址")
        }
        return (sessionId, proxyUrl)
    }

    public func registerStreamWithId(
        url: URL,
        headers: [String: String]
    ) async throws -> (sessionId: String, proxyUrl: URL) {
        let host = (url.host ?? "").lowercased()
        let isLoopback = (host == "127.0.0.1" || host == "localhost" || host == "::1")
        let policy = NetdiskHeaderPolicy(
            originUrl: url,
            baseHeaders: headers,
            cookieDomains: [],
            allowInsecureLoopbackCredentials: isLoopback,
            defaultUserAgent: CmsClient.defaultSafariUserAgent
        )
        return try await registerStreamWithId(url: url, policy: policy)
    }

    /// Registers an upstream media URL + origin-bound `NetdiskHeaderPolicy` and returns a loopback URL playable by `AVPlayer`.
    public func registerStream(url: URL, policy: NetdiskHeaderPolicy) async throws -> URL {
        try await registerStreamWithId(url: url, policy: policy).proxyUrl
    }

    /// Registers an upstream media URL + custom headers under an origin-bound isolation policy.
    public func registerStream(url: URL, headers: [String: String]) async throws -> URL {
        try await registerStreamWithId(url: url, headers: headers).proxyUrl
    }

    /// Rewrites an HLS `.m3u8` manifest so all variant playlists, media segments, and `#EXT-X-KEY` / `#EXT-X-MAP` URIs route through loopback.
    public static func rewriteM3u8Playlist(
        _ manifest: String,
        baseUrl: URL,
        proxyPort: UInt16,
        sessionId: String
    ) -> String {
        let baseStr = baseUrl.absoluteString
        func makeProxyUrl(_ rawRef: String) -> String {
            let trimmed = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return rawRef }
            let resolved = CmsParser.resolveUrl(base: baseStr, relative: trimmed)
            let b64 = Data(resolved.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let pathLower = (URL(string: resolved)?.path ?? "").lowercased()
            let suffix = pathLower.hasSuffix(".m3u8") ? "sub.m3u8" : "seg"
            return "http://127.0.0.1:\(proxyPort)/proxy/\(sessionId)/\(suffix)?u=\(b64)"
        }

        let uriAttrRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#, options: [.caseInsensitive])
        let lines = manifest.components(separatedBy: .newlines)
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rewritten.append("")
                continue
            }
            if trimmed.hasPrefix("#") {
                if let regex = uriAttrRegex, trimmed.uppercased().contains("URI=\"") {
                    let ns = trimmed as NSString
                    let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
                    if !matches.isEmpty {
                        let mutable = NSMutableString(string: trimmed)
                        for m in matches.reversed() {
                            let innerUri = ns.substring(with: m.range(at: 1))
                            let proxied = makeProxyUrl(innerUri)
                            mutable.replaceCharacters(in: m.range, with: "URI=\"\(proxied)\"")
                        }
                        rewritten.append(mutable as String)
                        continue
                    }
                }
                rewritten.append(trimmed)
                continue
            }
            rewritten.append(makeProxyUrl(trimmed))
        }
        return rewritten.joined(separator: "\n")
    }

    // MARK: - Loopback Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHttpRequest(connection: connection, accumulated: Data())
    }

    private func receiveHttpRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let chunk = data, !chunk.isEmpty {
                buffer.append(chunk)
            }
            if buffer.count > 65_536 {
                self.sendError(connection: connection, status: 413, message: "Request header too large")
                return
            }
            if let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                self.processRequestHeader(headerData, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHttpRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    private func processRequestHeader(_ headerData: Data, connection: NWConnection) {
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendError(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendError(connection: connection, status: 405, message: "Method Not Allowed")
            return
        }
        let rawTarget = parts[1]

        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            clientHeaders[key] = val
        }

        guard let comps = URLComponents(string: "http://127.0.0.1\(rawTarget.hasPrefix("/") ? "" : "/")\(rawTarget)") else {
            sendError(connection: connection, status: 400, message: "Invalid Target")
            return
        }
        let segments = comps.path.split(separator: "/").map(String.init)
        // Expected: /proxy/<sessionId>/<leaf>
        guard segments.count >= 2, segments[0] == "proxy" else {
            sendError(connection: connection, status: 404, message: "Not Found")
            return
        }
        let sessionId = segments[1]

        lock.lock()
        let session = sessions[sessionId]
        let activePort = port
        lock.unlock()

        guard let streamSession = session else {
            sendError(connection: connection, status: 404, message: "Expired stream session")
            return
        }

        let targetUrl: URL
        if let encodedU = comps.queryItems?.first(where: { $0.name == "u" })?.value, !encodedU.isEmpty {
            var b64 = encodedU
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64.append("=") }
            guard let decodedData = Data(base64Encoded: b64),
                  let decodedStr = String(data: decodedData, encoding: .utf8),
                  let resolvedUrl = URL(string: decodedStr),
                  let scheme = resolvedUrl.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https")
            else {
                sendError(connection: connection, status: 400, message: "Invalid sub-resource URL")
                return
            }
            targetUrl = resolvedUrl
        } else {
            targetUrl = streamSession.rootUrl
        }

        let requestedRange = clientHeaders["range"]
        let fetcher = self.upstreamFetcher
        let requestId = UUID()

        let requestTask = Task { [weak self] in
            guard let self = self else {
                connection.cancel()
                return
            }
            defer {
                self.unregisterActiveRequest(sessionId: sessionId, requestId: requestId)
            }
            do {
                var currentUrl = targetUrl
                var currentMethod = method
                var resolvedUpstream: ProxyUpstreamResponse?

                for _ in 0...Self.maxRedirects {
                    try Task.checkCancellation()
                    guard self.hasActiveSession(sessionId) else {
                        throw CancellationError()
                    }
                    guard let scheme = currentUrl.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                        self.sendError(connection: connection, status: 502, message: "Unsupported redirect scheme")
                        return
                    }
                    let hopHeaders = streamSession.policy.headers(for: currentUrl, range: requestedRange)
                    let hopResponse = try await fetcher(currentUrl, currentMethod, hopHeaders)
                    try Task.checkCancellation()
                    guard self.hasActiveSession(sessionId) else {
                        throw CancellationError()
                    }
                    if [301, 302, 303, 307, 308].contains(hopResponse.statusCode),
                       let rawLoc = hopResponse.headers.first(where: { $0.key.lowercased() == "location" })?.value
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       !rawLoc.isEmpty,
                       let nextUrl = URL(string: rawLoc, relativeTo: currentUrl)?.absoluteURL
                    {
                        if hopResponse.statusCode == 303 && currentMethod != "HEAD" {
                            currentMethod = "GET"
                        }
                        currentUrl = nextUrl
                        continue
                    }
                    resolvedUpstream = hopResponse
                    break
                }

                try Task.checkCancellation()
                guard self.hasActiveSession(sessionId) else {
                    throw CancellationError()
                }
                guard let upstream = resolvedUpstream else {
                    self.sendError(connection: connection, status: 502, message: "Too many upstream redirects")
                    return
                }

                let contentType = upstream.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
                let bodyPrefix = String(decoding: upstream.body.prefix(32), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isHls = currentUrl.path.lowercased().hasSuffix(".m3u8")
                    || contentType.lowercased().contains("mpegurl")
                    || bodyPrefix.hasPrefix("#EXTM3U")

                if isHls && upstream.statusCode >= 200 && upstream.statusCode < 300 {
                    let manifestText = String(decoding: upstream.body, as: UTF8.self)
                    let rewritten = Self.rewriteM3u8Playlist(
                        manifestText,
                        baseUrl: currentUrl,
                        proxyPort: activePort,
                        sessionId: sessionId
                    )
                    let payload = Data(rewritten.utf8)
                    self.sendResponse(
                        connection: connection,
                        status: 200,
                        headers: [
                            "Content-Type": "application/vnd.apple.mpegurl; charset=utf-8",
                            "Cache-Control": "no-store",
                            "Content-Length": "\(payload.count)",
                        ],
                        body: method == "HEAD" ? Data() : payload
                    )
                } else {
                    var respHeaders: [String: String] = [
                        "Cache-Control": "no-store",
                        "Content-Length": "\(upstream.body.count)",
                    ]
                    for forwarded in ["content-type", "content-range", "accept-ranges"] {
                        if let match = upstream.headers.first(where: { $0.key.lowercased() == forwarded }) {
                            respHeaders[match.key] = match.value
                        }
                    }
                    if respHeaders.keys.allSatisfy({ $0.lowercased() != "content-type" }) {
                        respHeaders["Content-Type"] = "application/octet-stream"
                    }
                    self.sendResponse(
                        connection: connection,
                        status: upstream.statusCode,
                        headers: respHeaders,
                        body: method == "HEAD" ? Data() : upstream.body
                    )
                }
            } catch is CancellationError {
                connection.cancel()
            } catch {
                if Task.isCancelled || !self.hasActiveSession(sessionId) {
                    connection.cancel()
                } else {
                    self.sendError(connection: connection, status: 502, message: "Upstream fetch failed")
                }
            }
        }

        let registered = registerActiveRequest(sessionId: sessionId, requestId: requestId) {
            requestTask.cancel()
            connection.cancel()
        }
        if !registered {
            requestTask.cancel()
            connection.cancel()
            return
        }

        // Cancel in-flight upstream download promptly if the client closes the socket early.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                requestTask.cancel()
            default:
                break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil {
                requestTask.cancel()
            }
        }
    }

    private func registerActiveRequest(
        sessionId: String,
        requestId: UUID,
        onCancel: @escaping @Sendable () -> Void
    ) -> Bool {
        withLock {
            guard sessions[sessionId] != nil else { return false }
            var map = activeRequestsBySession[sessionId] ?? [:]
            map[requestId] = ActiveRequestHandle(cancel: onCancel)
            activeRequestsBySession[sessionId] = map
            return true
        }
    }

    private func unregisterActiveRequest(sessionId: String, requestId: UUID) {
        withLock {
            guard var map = activeRequestsBySession[sessionId] else { return }
            map.removeValue(forKey: requestId)
            if map.isEmpty {
                activeRequestsBySession.removeValue(forKey: sessionId)
            } else {
                activeRequestsBySession[sessionId] = map
            }
        }
    }

    private func sendError(connection: NWConnection, status: Int, message: String) {
        let body = Data(message.utf8)
        sendResponse(
            connection: connection,
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(body.count)",
            ],
            body: body
        )
    }

    private func sendResponse(
        connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        let reason: String = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 502: "Bad Gateway"
        default: "Response"
        }
        var headerLines = ["HTTP/1.1 \(status) \(reason)", "Connection: close"]
        for (k, v) in headers {
            headerLines.append("\(k): \(v)")
        }
        let headerBlock = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var packet = Data(headerBlock.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

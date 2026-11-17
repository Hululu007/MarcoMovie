// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

/// Origin-bound credential & header isolation policy for Netdisk media streams.
/// Ensures `Cookie` and `Authorization` are strictly confined to trusted provider origins/domains
/// and are stripped on cross-domain CDN redirect hops, while always enforcing `Accept-Encoding: identity`.
public struct NetdiskHeaderPolicy: Hashable, Sendable {
    public let originUrl: URL
    public let baseHeaders: [String: String]
    public let cookieDomains: [String]
    public let allowInsecureLoopbackCredentials: Bool

    private static let sensitiveHeaderNames: Set<String> = [
        "cookie",
        "cookie2",
        "authorization",
        "proxy-authorization",
        "x-auth-token",
    ]

    public init(
        originUrl: URL,
        baseHeaders: [String: String] = [:],
        cookieDomains: [String] = [],
        allowInsecureLoopbackCredentials: Bool = false
    ) {
        self.originUrl = originUrl
        self.baseHeaders = baseHeaders
        self.cookieDomains = cookieDomains
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased() }
            .filter { $0.contains(".") && !$0.isEmpty }
        self.allowInsecureLoopbackCredentials = allowInsecureLoopbackCredentials
    }

    public func shouldSendCredentials(to targetUrl: URL) -> Bool {
        if let user = targetUrl.user, !user.isEmpty { return false }
        if let pass = targetUrl.password, !pass.isEmpty { return false }

        guard let targetScheme = targetUrl.scheme?.lowercased(),
              let targetHost = targetUrl.host?.lowercased(),
              !targetHost.isEmpty
        else {
            return false
        }

        let isLoopback = (targetHost == "127.0.0.1" || targetHost == "localhost")
        if targetScheme != "https" {
            guard allowInsecureLoopbackCredentials && targetScheme == "http" && isLoopback else {
                return false
            }
        }

        let originScheme = originUrl.scheme?.lowercased() ?? ""
        let originHost = originUrl.host?.lowercased() ?? ""
        let sameOriginHostAndPort = (targetScheme == originScheme)
            && (targetHost == originHost)
            && (Self.effectivePort(for: targetUrl) == Self.effectivePort(for: originUrl))
        if sameOriginHostAndPort {
            return true
        }

        guard targetScheme == "https" else {
            return false
        }
        for domain in cookieDomains {
            let targetMatches = (targetHost == domain) || targetHost.hasSuffix(".\(domain)")
            let originMatches = (originHost == domain) || originHost.hasSuffix(".\(domain)")
            if targetMatches && originMatches {
                return true
            }
        }
        return false
    }

    public func headers(for targetUrl: URL, range: String? = nil) -> [String: String] {
        let includeSecrets = shouldSendCredentials(to: targetUrl)
        var out: [String: String] = [:]

        for (rawKey, rawVal) in baseHeaders {
            let cleanKey = Self.sanitizeHeaderToken(rawKey)
            let cleanVal = Self.sanitizeHeaderToken(rawVal)
            guard !cleanKey.isEmpty, !cleanVal.isEmpty else { continue }
            let lowerKey = cleanKey.lowercased()
            if lowerKey == "accept-encoding" || lowerKey == "range" || lowerKey == "host" {
                continue
            }
            if Self.sensitiveHeaderNames.contains(lowerKey) && !includeSecrets {
                continue
            }
            out[cleanKey] = cleanVal
        }

        if out.keys.allSatisfy({ $0.lowercased() != "user-agent" }) {
            out["User-Agent"] = NetdiskService.desktopChromeUA
        }
        out["Accept-Encoding"] = "identity"
        if let range = range {
            let cleanRange = Self.sanitizeHeaderToken(range)
            if !cleanRange.isEmpty {
                out["Range"] = cleanRange
            }
        }
        return out
    }

    private static func effectivePort(for url: URL) -> Int {
        if let explicit = url.port { return explicit }
        return (url.scheme?.lowercased() == "https") ? 443 : 80
    }

    private static func sanitizeHeaderToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

public struct NetdiskProxyMetrics: Equatable, Sendable {
    public let currentBufferedBytes: Int
    public let peakBufferedBytes: Int
    public let preemptedWindowCount: Int
    public let upstreamChunkRequests: Int

    public init(
        currentBufferedBytes: Int,
        peakBufferedBytes: Int,
        preemptedWindowCount: Int,
        upstreamChunkRequests: Int
    ) {
        self.currentBufferedBytes = currentBufferedBytes
        self.peakBufferedBytes = peakBufferedBytes
        self.preemptedWindowCount = preemptedWindowCount
        self.upstreamChunkRequests = upstreamChunkRequests
    }
}

private final class ProxyNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Intercept every redirect hop so NetdiskHeaderPolicy re-evaluates target origin/domain before sending headers.
        completionHandler(nil)
    }
}

/// Global memory-ceiling accounting actor enforcing a strict upper bound (`defaultMemoryLimit = 24 MiB`)
/// across all in-flight and buffered Range chunks.
private actor ProxyMemoryBudgetActor {
    private let limitBytes: Int
    private var allocatedBytes: Int = 0
    private var peakBytes: Int = 0
    private var waiters: [(id: UUID, bytes: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limitBytes: Int) {
        self.limitBytes = max(65_536, limitBytes)
    }

    func acquire(bytes requested: Int) async -> Bool {
        if Task.isCancelled { return false }
        let needed = min(max(1, requested), limitBytes)
        if allocatedBytes + needed <= limitBytes && waiters.isEmpty {
            allocatedBytes += needed
            if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
            return true
        }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if allocatedBytes + needed <= limitBytes && waiters.isEmpty {
                    allocatedBytes += needed
                    if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
                    continuation.resume(returning: true)
                } else {
                    waiters.append((id: waiterId, bytes: needed, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterId)
            }
        }
    }

    func release(bytes released: Int) {
        let amount = min(max(1, released), limitBytes)
        allocatedBytes = max(0, allocatedBytes - amount)
        drainWaiters()
    }

    func resetAll() {
        allocatedBytes = 0
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.continuation.resume(returning: false)
        }
    }

    func snapshot() -> (current: Int, peak: Int) {
        (allocatedBytes, peakBytes)
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(returning: false)
        }
    }

    private func drainWaiters() {
        while let first = waiters.first, allocatedBytes + first.bytes <= limitBytes {
            waiters.removeFirst()
            allocatedBytes += first.bytes
            if allocatedBytes > peakBytes { peakBytes = allocatedBytes }
            first.continuation.resume(returning: true)
        }
    }
}

private struct UpstreamMediaMetadata: Sendable {
    let totalSize: Int64
    let contentType: String
    let supportsRange: Bool
}

private struct BufferedChunkEntry: Sendable {
    let data: Data
    let reservedBytes: Int
}

/// Per-resource sliding prefetch coordinator supporting parallel chunk workers and instant seek preemption.
private actor ResourceStreamCoordinator {
    let url: URL
    let policy: NetdiskHeaderPolicy
    let workers: Int
    let chunkSize: Int
    let contentTypeHint: String?
    private let memoryBudget: ProxyMemoryBudgetActor
    private let chunkFetcher: @Sendable (URL, String, String?, NetdiskHeaderPolicy) async throws -> ProxyUpstreamResponse

    private var cachedMetadata: UpstreamMediaMetadata?
    private var generation: UInt64 = 0
    private var activeWindowChunks: ClosedRange<Int>?
    private var inFlightTasks: [Int: (task: Task<Data, Error>, reservedBytes: Int)] = [:]
    private var readyChunks: [Int: BufferedChunkEntry] = [:]
    private var preemptedWindows: Int = 0
    private var totalChunkRequests: Int = 0

    init(
        url: URL,
        policy: NetdiskHeaderPolicy,
        workers: Int,
        chunkSize: Int,
        contentTypeHint: String?,
        memoryBudget: ProxyMemoryBudgetActor,
        chunkFetcher: @escaping @Sendable (URL, String, String?, NetdiskHeaderPolicy) async throws -> ProxyUpstreamResponse
    ) {
        self.url = url
        self.policy = policy
        self.workers = workers
        self.chunkSize = chunkSize
        self.contentTypeHint = contentTypeHint
        self.memoryBudget = memoryBudget
        self.chunkFetcher = chunkFetcher
    }

    func metricsSnapshot() -> (preempted: Int, chunkRequests: Int) {
        (preemptedWindows, totalChunkRequests)
    }

    func cancelAndPurgeAll() async {
        generation &+= 1
        activeWindowChunks = nil
        for (_, entry) in inFlightTasks {
            entry.task.cancel()
        }
        inFlightTasks.removeAll()
        for (_, ready) in readyChunks {
            await memoryBudget.release(bytes: ready.reservedBytes)
        }
        readyChunks.removeAll()
    }

    func resolveMetadata() async throws -> UpstreamMediaMetadata {
        if let existing = cachedMetadata {
            return existing
        }
        // Probe with Range: bytes=0-0 first (works with signed OSS/S3 GET URLs that forbid HEAD)
        let probe = try await chunkFetcher(url, "GET", "bytes=0-0", policy)
        if probe.statusCode == 206,
           let contentRange = headerValue(probe.headers, name: "content-range"),
           let total = Self.parseTotalSizeFromContentRange(contentRange)
        {
            let ct = resolvedContentType(from: probe.headers)
            let meta = UpstreamMediaMetadata(totalSize: total, contentType: ct, supportsRange: true)
            cachedMetadata = meta
            return meta
        }
        if (200...299).contains(probe.statusCode) {
            let lenHeader = headerValue(probe.headers, name: "content-length").flatMap { Int64($0) }
            let total = lenHeader ?? Int64(probe.body.count)
            let acceptRanges = headerValue(probe.headers, name: "accept-ranges")?.lowercased() ?? ""
            let ct = resolvedContentType(from: probe.headers)
            let meta = UpstreamMediaMetadata(
                totalSize: max(0, total),
                contentType: ct,
                supportsRange: acceptRanges.contains("bytes")
            )
            cachedMetadata = meta
            return meta
        }

        // Fallback to HEAD
        let headResp = try await chunkFetcher(url, "HEAD", nil, policy)
        guard (200...299).contains(headResp.statusCode) else {
            throw MarcoError.networkFailure("上游媒体探测失败 (HTTP \(headResp.statusCode))")
        }
        let total = headerValue(headResp.headers, name: "content-length").flatMap { Int64($0) } ?? 0
        let acceptRanges = headerValue(headResp.headers, name: "accept-ranges")?.lowercased() ?? ""
        let ct = resolvedContentType(from: headResp.headers)
        let meta = UpstreamMediaMetadata(
            totalSize: max(0, total),
            contentType: ct,
            supportsRange: acceptRanges.contains("bytes") || total > 0
        )
        cachedMetadata = meta
        return meta
    }

    /// Begins or advances a sliding prefetch window for `startByte...endByte`.
    /// Preempts and cancels stale in-flight chunk workers immediately if a non-contiguous seek occurs.
    func beginStreamSession(startByte: Int64, endByte: Int64, totalSize: Int64) async -> UInt64 {
        let firstChunk = Int(startByte / Int64(chunkSize))
        let lastChunk = Int(endByte / Int64(chunkSize))
        let totalChunks = max(1, Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize)))

        let isDisjointSeek: Bool = {
            guard let prev = activeWindowChunks else { return false }
            let hasActiveWork = !inFlightTasks.isEmpty || !readyChunks.isEmpty
            guard hasActiveWork else { return false }
            return firstChunk < prev.lowerBound || firstChunk > prev.upperBound + 1
        }()

        if isDisjointSeek {
            preemptedWindows += 1
            await cancelAndPurgeAll()
        } else {
            // Evict any chunks strictly behind firstChunk to reclaim memory budget
            let obsoleteReady = readyChunks.keys.filter { $0 < firstChunk }
            for idx in obsoleteReady {
                if let entry = readyChunks.removeValue(forKey: idx) {
                    await memoryBudget.release(bytes: entry.reservedBytes)
                }
            }
            let obsoleteInFlight = inFlightTasks.keys.filter { $0 < firstChunk }
            for idx in obsoleteInFlight {
                if let entry = inFlightTasks.removeValue(forKey: idx) {
                    entry.task.cancel()
                }
            }
        }

        let currentGen = generation
        let windowEnd = min(totalChunks - 1, max(lastChunk, firstChunk + workers - 1))
        activeWindowChunks = firstChunk...windowEnd
        scheduleWindowUpTo(
            cursorChunk: firstChunk,
            maxTargetChunk: min(totalChunks - 1, lastChunk + 1),
            totalSize: totalSize,
            expectedGen: currentGen
        )
        return currentGen
    }

    /// Consumes chunk `chunkIndex`, releasing its memory reservation once handed to the socket writer,
    /// and slides the parallel prefetch window forward.
    func consumeChunk(
        chunkIndex: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) async throws -> Data {
        guard generation == expectedGen, !Task.isCancelled else {
            throw CancellationError()
        }

        let totalChunks = max(1, Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
        scheduleWindowUpTo(
            cursorChunk: chunkIndex,
            maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
            totalSize: totalSize,
            expectedGen: expectedGen
        )

        if let ready = readyChunks.removeValue(forKey: chunkIndex) {
            await memoryBudget.release(bytes: ready.reservedBytes)
            advancePrefetchAfterConsumption(
                consumedChunk: chunkIndex,
                maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
                totalSize: totalSize,
                expectedGen: expectedGen
            )
            return ready.data
        }

        guard let inFlight = inFlightTasks[chunkIndex] else {
            throw CancellationError()
        }
        let data = try await inFlight.task.value
        guard generation == expectedGen, !Task.isCancelled else {
            throw CancellationError()
        }
        // If storeCompletedChunk already moved it to readyChunks, release there
        if let stored = readyChunks.removeValue(forKey: chunkIndex) {
            await memoryBudget.release(bytes: stored.reservedBytes)
        }
        advancePrefetchAfterConsumption(
            consumedChunk: chunkIndex,
            maxTargetChunk: min(totalChunks - 1, maxTargetChunk),
            totalSize: totalSize,
            expectedGen: expectedGen
        )
        return data
    }

    private func advancePrefetchAfterConsumption(
        consumedChunk: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) {
        let nextCursor = consumedChunk + 1
        guard nextCursor <= maxTargetChunk else { return }
        scheduleWindowUpTo(
            cursorChunk: nextCursor,
            maxTargetChunk: maxTargetChunk,
            totalSize: totalSize,
            expectedGen: expectedGen
        )
    }

    private func scheduleWindowUpTo(
        cursorChunk: Int,
        maxTargetChunk: Int,
        totalSize: Int64,
        expectedGen: UInt64
    ) {
        guard generation == expectedGen, cursorChunk <= maxTargetChunk else { return }
        let upper = min(maxTargetChunk, cursorChunk + workers - 1)
        guard cursorChunk <= upper else { return }
        activeWindowChunks = cursorChunk...upper

        for cIdx in cursorChunk...upper {
            if readyChunks[cIdx] != nil || inFlightTasks[cIdx] != nil {
                continue
            }
            if inFlightTasks.count >= workers {
                break
            }
            let cStart = Int64(cIdx) * Int64(chunkSize)
            let cEnd = min(totalSize - 1, cStart + Int64(chunkSize) - 1)
            let expectedLen = Int(cEnd - cStart + 1)
            guard expectedLen > 0 else { continue }

            totalChunkRequests += 1
            let mediaUrl = self.url
            let hdrPolicy = self.policy
            let fetcher = self.chunkFetcher
            let budget = self.memoryBudget
            let coordinator = self

            let task = Task.detached(priority: .userInitiated) { () throws -> Data in
                let acquired = await budget.acquire(bytes: expectedLen)
                guard acquired, !Task.isCancelled else {
                    throw CancellationError()
                }
                do {
                    let rangeHdr = "bytes=\(cStart)-\(cEnd)"
                    let resp = try await fetcher(mediaUrl, "GET", rangeHdr, hdrPolicy)
                    try Task.checkCancellation()

                    let payload: Data
                    if resp.statusCode == 206 {
                        payload = resp.body
                    } else if resp.statusCode == 200 {
                        // Upstream ignored Range and returned whole representation; slice requested window safely
                        let lower = Int(cStart)
                        let upperIdx = min(resp.body.count, Int(cEnd) + 1)
                        guard lower < upperIdx else {
                            throw MarcoError.networkFailure("上游分片偏移超出响应长度")
                        }
                        payload = resp.body.subdata(in: lower..<upperIdx)
                    } else {
                        throw MarcoError.networkFailure("上游分片请求失败 (HTTP \(resp.statusCode))")
                    }

                    await coordinator.storeCompletedChunk(
                        chunkIndex: cIdx,
                        data: payload,
                        reservedBytes: expectedLen,
                        expectedGen: expectedGen
                    )
                    return payload
                } catch {
                    await budget.release(bytes: expectedLen)
                    await coordinator.removeFailedInFlight(chunkIndex: cIdx, expectedGen: expectedGen)
                    throw error
                }
            }
            inFlightTasks[cIdx] = (task: task, reservedBytes: expectedLen)
        }
    }

    private func storeCompletedChunk(
        chunkIndex: Int,
        data: Data,
        reservedBytes: Int,
        expectedGen: UInt64
    ) async {
        guard generation == expectedGen, inFlightTasks[chunkIndex] != nil else {
            await memoryBudget.release(bytes: reservedBytes)
            return
        }
        inFlightTasks.removeValue(forKey: chunkIndex)
        readyChunks[chunkIndex] = BufferedChunkEntry(data: data, reservedBytes: reservedBytes)
    }

    private func removeFailedInFlight(chunkIndex: Int, expectedGen: UInt64) {
        guard generation == expectedGen else { return }
        inFlightTasks.removeValue(forKey: chunkIndex)
    }

    private func headerValue(_ headers: [String: String], name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.key.lowercased() == lower })?.value
    }

    private func resolvedContentType(from headers: [String: String]) -> String {
        if let hint = contentTypeHint, !hint.isEmpty { return hint }
        if let upstream = headerValue(headers, name: "content-type"), !upstream.isEmpty {
            return upstream
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "mov": return "video/quicktime"
        case "ts": return "video/mp2t"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return "application/octet-stream"
        }
    }

    static func parseTotalSizeFromContentRange(_ header: String) -> Int64? {
        // Expected: "bytes 0-0/1048576" or "bytes */1048576"
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let tail = header[header.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail != "*", let size = Int64(tail), size >= 0 else { return nil }
        return size
    }
}

/// Loopback (`127.0.0.1:<ephemeral>`) 6-worker Range proxy server for Apple TV 4K Netdisk playback.
/// Provides revocable capability URLs (`/<token>/<resourceId>/media`), per-hop `NetdiskHeaderPolicy`
/// redirect credential isolation, `24 MiB` memory ceiling backpressure, and instant seek preemption.
public final class NetdiskRangeProxyServer: @unchecked Sendable {
    public static let defaultWorkers = 6
    public static let defaultChunkSize = 1_048_576
    public static let defaultMemoryLimit = 24 * 1024 * 1024
    private static let maxRedirects = 8

    public let workers: Int
    public let chunkSize: Int
    public let memoryLimit: Int

    private let queue = DispatchQueue(label: "com.pilipala.marcoMovie.tv.range-proxy", qos: .userInitiated)
    private let stateLock = NSLock()
    private var serverToken: String
    private var resources: [String: ResourceStreamCoordinator] = [:]
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0

    private let memoryBudget: ProxyMemoryBudgetActor
    private let redirectDelegate = ProxyNoRedirectDelegate()
    private let urlSession: URLSession
    private let chunkFetcher: @Sendable (URL, String, String?, NetdiskHeaderPolicy) async throws -> ProxyUpstreamResponse

    public init(
        workers: Int = NetdiskRangeProxyServer.defaultWorkers,
        chunkSize: Int = NetdiskRangeProxyServer.defaultChunkSize,
        memoryLimit: Int = NetdiskRangeProxyServer.defaultMemoryLimit,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.workers = min(max(1, workers), 6)
        self.chunkSize = min(max(65_536, chunkSize), 2 * 1024 * 1024)
        self.memoryLimit = max(self.chunkSize * 2, memoryLimit)
        self.serverToken = Self.randomHex(byteCount: 16)
        self.memoryBudget = ProxyMemoryBudgetActor(limitBytes: self.memoryLimit)

        let cfg = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 20
            c.timeoutIntervalForResource = 120
            c.httpMaximumConnectionsPerHost = 8
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            return c
        }()
        let session = URLSession(configuration: cfg, delegate: redirectDelegate, delegateQueue: nil)
        self.urlSession = session
        self.chunkFetcher = { targetUrl, method, rangeHeader, policy in
            try await Self.fetchFollowingRedirects(
                session: session,
                initialUrl: targetUrl,
                method: method,
                range: rangeHeader,
                policy: policy
            )
        }
    }

    deinit {
        stop()
    }

    public var currentToken: String {
        withStateLock { serverToken }
    }

    public func startIfNeeded() async throws -> UInt16 {
        if let existing = withStateLock({ () -> UInt16? in
            (listener != nil && port > 0) ? port : nil
        }) {
            return existing
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let nwListener = try NWListener(using: params)
        nwListener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
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
                        continuation.resume(throwing: MarcoError.networkFailure("分片代理端口分配失败"))
                    }
                case .failed(let err):
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: MarcoError.networkFailure("分片代理启动失败：\(err)"))
                case .cancelled:
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: MarcoError.networkFailure("分片代理已关闭"))
                default:
                    break
                }
            }
            nwListener.start(queue: self.queue)
        }

        withStateLock {
            self.listener = nwListener
            self.port = boundPort
        }
        return boundPort
    }

    public func stop() {
        let (activeListener, oldResources) = withStateLock { () -> (NWListener?, [ResourceStreamCoordinator]) in
            let current = listener
            listener = nil
            port = 0
            let all = Array(resources.values)
            resources.removeAll()
            serverToken = Self.randomHex(byteCount: 16)
            return (current, all)
        }
        activeListener?.cancel()
        let budget = self.memoryBudget
        Task {
            for coord in oldResources {
                await coord.cancelAndPurgeAll()
            }
            await budget.resetAll()
        }
    }

    /// Rotates the capability token and purges all active streams immediately.
    public func revokeAll() async {
        let oldResources = withStateLock { () -> [ResourceStreamCoordinator] in
            serverToken = Self.randomHex(byteCount: 16)
            let all = Array(resources.values)
            resources.removeAll()
            return all
        }
        for coord in oldResources {
            await coord.cancelAndPurgeAll()
        }
        await memoryBudget.resetAll()
    }

    public func revokeResource(_ resourceId: String) async {
        let removed = withStateLock { resources.removeValue(forKey: resourceId) }
        await removed?.cancelAndPurgeAll()
    }

    /// Registers an upstream media URL with a `NetdiskHeaderPolicy` and returns `http://127.0.0.1:<port>/<token>/<resourceId>/media`.
    public func registerStream(
        url: URL,
        policy: NetdiskHeaderPolicy,
        contentTypeHint: String? = nil
    ) async throws -> (resourceId: String, proxyUrl: URL) {
        let activePort = try await startIfNeeded()
        let resourceId = Self.randomHex(byteCount: 12)
        let coordinator = ResourceStreamCoordinator(
            url: url,
            policy: policy,
            workers: workers,
            chunkSize: chunkSize,
            contentTypeHint: contentTypeHint,
            memoryBudget: memoryBudget,
            chunkFetcher: chunkFetcher
        )

        let tokenSnapshot = withStateLock { () -> String in
            if resources.count >= 32, let evictedKey = resources.keys.first {
                let evicted = resources.removeValue(forKey: evictedKey)
                Task { await evicted?.cancelAndPurgeAll() }
            }
            resources[resourceId] = coordinator
            return serverToken
        }

        guard let proxyUrl = URL(string: "http://127.0.0.1:\(activePort)/\(tokenSnapshot)/\(resourceId)/media") else {
            throw MarcoError.networkFailure("无法构造分片代理播放地址")
        }
        return (resourceId, proxyUrl)
    }

    public func metrics() async -> NetdiskProxyMetrics {
        let coords = withStateLock { Array(resources.values) }
        var totalPreempted = 0
        var totalChunkReqs = 0
        for c in coords {
            let snap = await c.metricsSnapshot()
            totalPreempted += snap.preempted
            totalChunkReqs += snap.chunkRequests
        }
        let mem = await memoryBudget.snapshot()
        return NetdiskProxyMetrics(
            currentBufferedBytes: mem.current,
            peakBufferedBytes: mem.peak,
            preemptedWindowCount: totalPreempted,
            upstreamChunkRequests: totalChunkReqs
        )
    }

    // MARK: - Redirect-Filtered Upstream Fetcher

    public static func fetchFollowingRedirects(
        session: URLSession,
        initialUrl: URL,
        method: String,
        range: String?,
        policy: NetdiskHeaderPolicy
    ) async throws -> ProxyUpstreamResponse {
        var currentUrl = initialUrl
        var currentMethod = method.uppercased()

        for _ in 0...maxRedirects {
            try Task.checkCancellation()
            guard let scheme = currentUrl.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw MarcoError.networkFailure("不支持的重定向协议")
            }

            var req = URLRequest(url: currentUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.httpMethod = currentMethod
            req.httpShouldHandleCookies = false
            let filteredHeaders = policy.headers(for: currentUrl, range: range)
            for (k, v) in filteredHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return ProxyUpstreamResponse(statusCode: 200, headers: [:], body: data)
            }

            let status = http.statusCode
            if [301, 302, 303, 307, 308].contains(status),
               let location = http.value(forHTTPHeaderField: "Location")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !location.isEmpty,
               let nextUrl = URL(string: location, relativeTo: currentUrl)?.absoluteURL
            {
                if status == 303 && currentMethod != "HEAD" {
                    currentMethod = "GET"
                }
                currentUrl = nextUrl
                continue
            }

            var respHeaders: [String: String] = [:]
            for (rk, rv) in http.allHeaderFields {
                respHeaders[String(describing: rk)] = String(describing: rv)
            }
            return ProxyUpstreamResponse(statusCode: status, headers: respHeaders, body: data)
        }

        throw MarcoError.networkFailure("上游重定向次数超过上限 (\(maxRedirects))")
    }

    // MARK: - Loopback HTTP Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, accumulated: Data())
    }

    private func receiveHeader(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let chunk = chunk, !chunk.isEmpty {
                buffer.append(chunk)
            }
            if buffer.count > 65_536 {
                self.sendSimpleResponse(connection: connection, status: 413, headers: [:], body: Data("Header Too Large".utf8))
                return
            }
            if let sep = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerSlice = buffer.subdata(in: 0..<sep.lowerBound)
                self.dispatchRequest(headerData: headerSlice, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveHeader(connection: connection, accumulated: buffer)
            }
        }
    }

    private enum ParsedRangeResult {
        case none
        case valid(start: Int64, end: Int64)
        case unsatisfiable
    }

    private static func parseByteRange(_ rawHeader: String?, totalSize: Int64) -> ParsedRangeResult {
        guard let raw = rawHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .none
        }
        guard raw.lowercased().hasPrefix("bytes=") else {
            return .unsatisfiable
        }
        let spec = String(raw.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        // Reject multi-part byte ranges
        guard !spec.contains(","), let dashIdx = spec.firstIndex(of: "-") else {
            return .unsatisfiable
        }
        guard totalSize > 0 else {
            return .unsatisfiable
        }

        let startPart = String(spec[..<dashIdx]).trimmingCharacters(in: .whitespaces)
        let endPart = String(spec[spec.index(after: dashIdx)...]).trimmingCharacters(in: .whitespaces)

        if startPart.isEmpty {
            // Suffix byte-range-spec: bytes=-500
            guard let suffixLen = Int64(endPart), suffixLen > 0 else {
                return .unsatisfiable
            }
            let clampedStart = max(0, totalSize - suffixLen)
            return .valid(start: clampedStart, end: totalSize - 1)
        }

        guard let start = Int64(startPart), start >= 0, start < totalSize else {
            return .unsatisfiable
        }
        if endPart.isEmpty {
            return .valid(start: start, end: totalSize - 1)
        }
        guard let requestedEnd = Int64(endPart), requestedEnd >= start else {
            return .unsatisfiable
        }
        return .valid(start: start, end: min(requestedEnd, totalSize - 1))
    }

    private func dispatchRequest(headerData: Data, connection: NWConnection) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(connection: connection, status: 400, headers: [:], body: Data("Bad Request".utf8))
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendSimpleResponse(connection: connection, status: 400, headers: [:], body: Data("Bad Request".utf8))
            return
        }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(connection: connection, status: 405, headers: ["Allow": "GET, HEAD"], body: Data("Method Not Allowed".utf8))
            return
        }

        let rawPath = parts[1].components(separatedBy: "?").first ?? parts[1]
        let segments = rawPath.split(separator: "/").map(String.init)
        // Expected path: /<token>/<resourceId>/media (or /<token>/<resourceId>/media.<ext>)
        guard segments.count == 3, segments[2].hasPrefix("media") else {
            sendSimpleResponse(connection: connection, status: 404, headers: [:], body: Data("Not Found".utf8))
            return
        }

        let reqToken = segments[0]
        let resourceId = segments[1]

        let lookup = withStateLock { () -> (tokenValid: Bool, coordinator: ResourceStreamCoordinator?) in
            guard reqToken == serverToken else { return (false, nil) }
            return (true, resources[resourceId])
        }

        guard lookup.tokenValid else {
            sendSimpleResponse(connection: connection, status: 403, headers: [:], body: Data("Forbidden".utf8))
            return
        }
        guard let coordinator = lookup.coordinator else {
            sendSimpleResponse(connection: connection, status: 404, headers: [:], body: Data("Expired Resource".utf8))
            return
        }

        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            clientHeaders[k] = v
        }
        let rangeHeader = clientHeaders["range"]

        Task { [weak self] in
            guard let self = self else {
                connection.cancel()
                return
            }
            await self.serveMediaRequest(
                method: method,
                rangeHeader: rangeHeader,
                coordinator: coordinator,
                connection: connection
            )
        }
    }

    private func serveMediaRequest(
        method: String,
        rangeHeader: String?,
        coordinator: ResourceStreamCoordinator,
        connection: NWConnection
    ) async {
        do {
            let meta = try await coordinator.resolveMetadata()
            let parsedRange = Self.parseByteRange(rangeHeader, totalSize: meta.totalSize)

            switch parsedRange {
            case .unsatisfiable:
                sendSimpleResponse(
                    connection: connection,
                    status: 416,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes */\(meta.totalSize)",
                        "Cache-Control": "no-store",
                    ],
                    body: method == "HEAD" ? Data() : Data("Range Not Satisfiable".utf8)
                )
                return

            case .none:
                let baseHeaders: [String: String] = [
                    "Accept-Ranges": "bytes",
                    "Content-Type": meta.contentType,
                    "Content-Length": "\(meta.totalSize)",
                    "Cache-Control": "no-store",
                ]
                if method == "HEAD" || meta.totalSize == 0 {
                    sendSimpleResponse(connection: connection, status: 200, headers: baseHeaders, body: Data())
                    return
                }
                try await streamRangeBody(
                    status: 200,
                    headers: baseHeaders,
                    startByte: 0,
                    endByte: meta.totalSize - 1,
                    totalSize: meta.totalSize,
                    coordinator: coordinator,
                    connection: connection
                )

            case .valid(let startByte, let endByte):
                let contentLen = endByte - startByte + 1
                let rangeHeaders: [String: String] = [
                    "Accept-Ranges": "bytes",
                    "Content-Type": meta.contentType,
                    "Content-Range": "bytes \(startByte)-\(endByte)/\(meta.totalSize)",
                    "Content-Length": "\(contentLen)",
                    "Cache-Control": "no-store",
                ]
                if method == "HEAD" {
                    sendSimpleResponse(connection: connection, status: 206, headers: rangeHeaders, body: Data())
                    return
                }
                try await streamRangeBody(
                    status: 206,
                    headers: rangeHeaders,
                    startByte: startByte,
                    endByte: endByte,
                    totalSize: meta.totalSize,
                    coordinator: coordinator,
                    connection: connection
                )
            }
        } catch is CancellationError {
            connection.cancel()
        } catch {
            sendSimpleResponse(
                connection: connection,
                status: 502,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: method == "HEAD" ? Data() : Data("Upstream Stream Error".utf8)
            )
        }
    }

    private func streamRangeBody(
        status: Int,
        headers: [String: String],
        startByte: Int64,
        endByte: Int64,
        totalSize: Int64,
        coordinator: ResourceStreamCoordinator,
        connection: NWConnection
    ) async throws {
        let sessionGen = await coordinator.beginStreamSession(
            startByte: startByte,
            endByte: endByte,
            totalSize: totalSize
        )
        let firstChunk = Int(startByte / Int64(chunkSize))
        let lastChunk = Int(endByte / Int64(chunkSize))

        let headerPacket = Data(Self.formatHttpHeaderBlock(status: status, headers: headers).utf8)
        try await Self.sendPacket(connection: connection, data: headerPacket)

        for cIdx in firstChunk...lastChunk {
            let chunkData = try await coordinator.consumeChunk(
                chunkIndex: cIdx,
                maxTargetChunk: lastChunk + 1,
                totalSize: totalSize,
                expectedGen: sessionGen
            )
            let chunkGlobalStart = Int64(cIdx) * Int64(chunkSize)
            let sliceStart = Int(max(0, startByte - chunkGlobalStart))
            let sliceEnd = Int(min(Int64(chunkData.count), endByte - chunkGlobalStart + 1))
            guard sliceStart < sliceEnd, sliceEnd <= chunkData.count else {
                throw MarcoError.networkFailure("分片数据长度与请求范围不匹配")
            }
            let slice = (sliceStart == 0 && sliceEnd == chunkData.count)
                ? chunkData
                : chunkData.subdata(in: sliceStart..<sliceEnd)
            try await Self.sendPacket(connection: connection, data: slice)
        }

        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Socket & State Helpers

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private static func formatHttpHeaderBlock(status: Int, headers: [String: String]) -> String {
        let reason: String = switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 502: "Bad Gateway"
        default: "Response"
        }
        var lines = ["HTTP/1.1 \(status) \(reason)", "Connection: close"]
        for (k, v) in headers {
            lines.append("\(k): \(v)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func sendSimpleResponse(
        connection: NWConnection,
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        var merged = headers
        if merged.keys.allSatisfy({ $0.lowercased() != "content-length" }) {
            merged["Content-Length"] = "\(body.count)"
        }
        var packet = Data(Self.formatHttpHeaderBlock(status: status, headers: merged).utf8)
        packet.append(body)
        connection.send(content: packet, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func sendPacket(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

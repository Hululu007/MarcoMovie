// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoTVCore

// MARK: - Deterministic Mock Playback Engine & Async Resolution Gate

@MainActor
private final class MockPlaybackEngineAdapter: PlaybackEngineAdapterProtocol {
    struct LoadCall: Equatable {
        let token: UInt64
        let url: URL
        let initialSeekMs: Int
        let rate: Float
    }

    var activeItemToken: UInt64?
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)?
    var onPlaybackEnded: ((_ token: UInt64) -> Void)?
    var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)?

    private(set) var loadCalls: [LoadCall] = []
    private(set) var stopCount: Int = 0
    private(set) var teardownCalled: Bool = false
    private(set) var lastRate: Float = 1.0

    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float) {
        activeItemToken = token
        currentTimeMs = initialSeekMs
        lastRate = rate
        loadCalls.append(LoadCall(token: token, url: url, initialSeekMs: initialSeekMs, rate: rate))
    }

    func stopCurrentItem() {
        stopCount += 1
        activeItemToken = nil
        currentTimeMs = 0
        durationMs = 0
    }

    func setPlaybackRate(_ rate: Float) {
        lastRate = rate
    }

    func teardown() {
        teardownCalled = true
        stopCurrentItem()
    }

    func emitTick(token: UInt64, posMs: Int, durMs: Int) {
        if activeItemToken == token {
            currentTimeMs = posMs
            durationMs = durMs
        }
        onProgressTick?(token, posMs, durMs)
    }

    func emitEnded(token: UInt64) {
        onPlaybackEnded?(token)
    }

    func emitFailed(token: UInt64, message: String) {
        onPlaybackFailed?(token, message)
    }
}

private actor AsyncResolutionGate {
    private var enteredWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var enteredKeys: Set<String> = []
    private var releaseWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var preReleased: Set<String> = []
    private var cancelledKeys: Set<String> = []

    func waitUntilReleased(key: String) async throws {
        enteredKeys.insert(key)
        if let ew = enteredWaiters.removeValue(forKey: key) {
            ew.resume()
        }
        if preReleased.remove(key) != nil {
            try Task.checkCancellation()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cancelledKeys.insert(key)
                    cont.resume(throwing: CancellationError())
                } else if preReleased.remove(key) != nil {
                    cont.resume()
                } else {
                    releaseWaiters[key] = cont
                }
            }
        } onCancel: {
            Task { await self.markCancelled(key: key) }
        }
    }

    func waitUntilEntered(key: String) async {
        if enteredKeys.contains(key) { return }
        await withCheckedContinuation { cont in
            if enteredKeys.contains(key) {
                cont.resume()
            } else {
                enteredWaiters[key] = cont
            }
        }
    }

    func release(key: String) {
        if let rw = releaseWaiters.removeValue(forKey: key) {
            rw.resume()
        } else {
            preReleased.insert(key)
        }
    }

    func wasCancelled(key: String) -> Bool {
        cancelledKeys.contains(key)
    }

    private func markCancelled(key: String) {
        cancelledKeys.insert(key)
        if let rw = releaseWaiters.removeValue(forKey: key) {
            rw.resume(throwing: CancellationError())
        }
    }
}

private final class StubCmsLockedBox<Value>: @unchecked Sendable {
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

private final class StubCmsURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = StubCmsLockedBox<Handler?>(nil)

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

// MARK: - Batch 2 Regression Tests (Items 4 & 5)

final class PlaybackAndMediaEntryTests: XCTestCase {
    override func tearDown() {
        StubCmsURLProtocol.uninstall()
        super.tearDown()
    }

    private func makeTestVodSiteAndVideo() -> (CmsSite, CmsVideo) {
        let site = CmsSite(key: "site_vod", name: "测试点播站", type: 1, api: "https://vod.example/api.php/provide/vod")
        let line0 = CmsLine(
            name: "主线",
            episodes: [
                CmsEpisode(name: "第1集", url: "https://cdn.example/ep_a.m3u8"),
                CmsEpisode(name: "第2集", url: "https://cdn.example/ep_b.m3u8"),
                CmsEpisode(name: "第3集", url: "https://cdn.example/ep_c.m3u8"),
            ]
        )
        let line1 = CmsLine(
            name: "备用线",
            episodes: [
                CmsEpisode(name: "第1集", url: "https://cdn.example/backup_ep_a.m3u8"),
                CmsEpisode(name: "第2集", url: "https://cdn.example/backup_ep_b.m3u8"),
                CmsEpisode(name: "第3集", url: "https://cdn.example/backup_ep_c.m3u8"),
            ]
        )
        let video = CmsVideo(
            id: "v100",
            title: "测试剧集",
            poster: "https://cdn.example/poster.jpg",
            remarks: "更新至3集",
            lines: [line0, line1]
        )
        return (site, video)
    }

    // MARK: - Item 4: Rapid Switch (A Playing -> B Slow -> C Fast)

    @MainActor
    func testRapidEpisodeSwitchAPlayingBSlowCFast() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoBatch2Switch_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())

        let (site, video) = makeTestVodSiteAndVideo()
        let engine = MockPlaybackEngineAdapter()
        let gate = AsyncResolutionGate()
        var recordedHistoryEvents: [(episode: String, pos: Int)] = []

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
            engine: engine,
            resolver: { descriptor in
                let ep = descriptor.currentEpisode!
                if ep.url.hasSuffix("ep_b.m3u8") {
                    try await gate.waitUntilReleased(key: "B")
                }
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: false,
                    kernelLabel: "AVKit 硬解",
                    resolutionBadge: "1080P"
                )
            },
            progressRecorder: { desc, posMs, durMs in
                guard let line = desc.currentLine, let ep = desc.currentEpisode else { return }
                recordedHistoryEvents.append((ep.name, posMs))
                storage.upsertWatchHistory(
                    WatchHistoryItem(
                        site: desc.site.key,
                        id: desc.video.id,
                        title: desc.video.title,
                        poster: desc.video.poster,
                        line: line.name,
                        episode: ep.name,
                        index: desc.episodeIndex,
                        position: posMs,
                        duration: durMs,
                        updated: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                )
            }
        )

        // 1) A starts playing and reaches 120_000 ms
        coordinator.startInitialLoad()
        try await waitUntil { engine.loadCalls.count == 1 }
        let tokenA = try XCTUnwrap(engine.loadCalls.first?.token)
        XCTAssertEqual(engine.loadCalls[0].url.absoluteString, "https://cdn.example/ep_a.m3u8")
        engine.emitTick(token: tokenA, posMs: 120_000, durMs: 2_400_000)

        // 2) User switches to B (intentionally slow)
        coordinator.switchToEpisode(lineIndex: 0, episodeIndex: 1, seekMs: 0)
        await gate.waitUntilEntered(key: "B")
        XCTAssertTrue(coordinator.isResolving)
        XCTAssertNil(coordinator.activeLoaded)

        // Stale progress tick from A while B is resolving must be dropped
        engine.emitTick(token: tokenA, posMs: 155_000, durMs: 2_400_000)

        // 3) User immediately switches to C (fast) before B finishes
        coordinator.switchToEpisode(lineIndex: 0, episodeIndex: 2, seekMs: 0)
        try await waitUntil { engine.loadCalls.count == 2 }
        XCTAssertEqual(engine.loadCalls[1].url.absoluteString, "https://cdn.example/ep_c.m3u8")
        XCTAssertEqual(coordinator.activeLoaded?.episodeIndex, 2)
        XCTAssertFalse(coordinator.isResolving)

        // 4) Late release of B must NOT load B or corrupt active item / history
        await gate.release(key: "B")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(engine.loadCalls.count, 2, "B must never be loaded into player")
        XCTAssertEqual(engine.loadCalls.map(\.url.absoluteString), [
            "https://cdn.example/ep_a.m3u8",
            "https://cdn.example/ep_c.m3u8",
        ])
        let bWasCancelled = await gate.wasCancelled(key: "B")
        XCTAssertTrue(bWasCancelled, "Slow B resolution task must be cancelled when switching to C")

        // Stale callbacks from token A must be ignored while C plays
        engine.emitPlaybackEventsCheck(tokenA: tokenA, coordinator: coordinator)

        // Verify A's exact breakpoint (120_000 ms) was preserved and B has ZERO false progress
        XCTAssertFalse(recordedHistoryEvents.contains(where: { $0.episode == "第2集" }), "B must have zero recorded progress")
        XCTAssertFalse(recordedHistoryEvents.contains(where: { $0.pos == 155_000 }), "Stale tick after A detached must be dropped")
        let saved = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == site.key && $0.id == video.id }))
        XCTAssertEqual(saved.episode, "第1集")
        XCTAssertEqual(saved.resumePosition, 120_000)

        // Now C ticks to 30_000 ms -> history cleanly updates to C
        let tokenC = try XCTUnwrap(engine.activeItemToken)
        engine.emitTick(token: tokenC, posMs: 30_000, durMs: 2_500_000)
        let savedAfterC = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == site.key && $0.id == video.id }))
        XCTAssertEqual(savedAfterC.episode, "第3集")
        XCTAssertEqual(savedAfterC.resumePosition, 30_000)
    }

    // MARK: - Item 4: Exit During Resolution Cancels & Never Loads

    @MainActor
    func testExitDuringStreamResolutionCancelsAndNeverLoads() async throws {
        let (site, video) = makeTestVodSiteAndVideo()
        let engine = MockPlaybackEngineAdapter()
        let gate = AsyncResolutionGate()
        var savedCount = 0

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
            engine: engine,
            resolver: { descriptor in
                try await gate.waitUntilReleased(key: "exit_case")
                let ep = descriptor.currentEpisode!
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: false,
                    kernelLabel: "AVKit 硬解",
                    resolutionBadge: "1080P"
                )
            },
            progressRecorder: { _, _, _ in
                savedCount += 1
            }
        )

        coordinator.startInitialLoad()
        await gate.waitUntilEntered(key: "exit_case")
        coordinator.teardownAndPersist()

        await gate.release(key: "exit_case")
        try await Task.sleep(nanoseconds: 50_000_000)

        let cancelled = await gate.wasCancelled(key: "exit_case")
        XCTAssertTrue(cancelled)
        XCTAssertTrue(engine.teardownCalled)
        XCTAssertTrue(engine.loadCalls.isEmpty, "No player item may load after teardown")
        XCTAssertEqual(savedCount, 0)
    }

    // MARK: - Item 4: Duplicate Outro & End Callbacks Trigger Auto-Advance Once

    @MainActor
    func testDuplicateOutroAndEndCallbacksTriggerAutoAdvanceOnce() async throws {
        let (site, video) = makeTestVodSiteAndVideo()
        let engine = MockPlaybackEngineAdapter()

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
            engine: engine,
            resolver: { descriptor in
                let ep = descriptor.currentEpisode!
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: false,
                    kernelLabel: "AVKit 硬解",
                    resolutionBadge: "1080P"
                )
            },
            progressRecorder: { _, _, _ in },
            skipIntroSec: 15,
            skipOutroSec: 60,
            autoNext: true
        )

        coordinator.startInitialLoad()
        try await waitUntil { engine.loadCalls.count == 1 }
        let token1 = try XCTUnwrap(engine.activeItemToken)

        // Fire repeated outro ticks + duplicate end notifications for token 1
        engine.emitTick(token: token1, posMs: 2_345_000, durMs: 2_400_000)
        engine.emitTick(token: token1, posMs: 2_350_000, durMs: 2_400_000)
        engine.emitEnded(token: token1)
        engine.emitEnded(token: token1)

        try await waitUntil { engine.loadCalls.count == 2 }
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(engine.loadCalls.count, 2, "Auto-advance must fire exactly once")
        XCTAssertEqual(coordinator.target.episodeIndex, 1, "Must land on EP 2, not skip to EP 3")
        XCTAssertEqual(engine.loadCalls[1].url.absoluteString, "https://cdn.example/ep_b.m3u8")
        XCTAssertEqual(engine.loadCalls[1].initialSeekMs, 15_000)
    }

    // MARK: - Item 4: Playback Load & Mid-Playback Failure -> Retry / Switch Line

    @MainActor
    func testPlaybackItemLoadAndMidPlaybackFailureSurfacesRetryAndLineSwitch() async throws {
        let (site, video) = makeTestVodSiteAndVideo()
        let engine = MockPlaybackEngineAdapter()

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(site: site, video: video, lineIndex: 0, episodeIndex: 0),
            engine: engine,
            resolver: { descriptor in
                let ep = descriptor.currentEpisode!
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: false,
                    kernelLabel: "AVKit 硬解",
                    resolutionBadge: "1080P"
                )
            },
            progressRecorder: { _, _, _ in }
        )

        coordinator.startInitialLoad()
        try await waitUntil { engine.loadCalls.count == 1 }
        let tok1 = try XCTUnwrap(engine.activeItemToken)

        // 1) Load failure surfaces errorIsPlaybackFailure == true
        engine.emitFailed(token: tok1, message: "媒体加载失败 (HTTP 403)")
        XCTAssertTrue(coordinator.errorIsPlaybackFailure)
        XCTAssertEqual(coordinator.errorMessage, "媒体加载失败 (HTTP 403)")
        XCTAssertNil(coordinator.activeLoaded)

        // 2) Retry recovers cleanly
        coordinator.retryCurrent()
        try await waitUntil { engine.loadCalls.count == 2 }
        let tok2 = try XCTUnwrap(engine.activeItemToken)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(coordinator.errorIsPlaybackFailure)

        // Stale failure from tok1 must be ignored
        engine.emitFailed(token: tok1, message: "迟到的旧错误")
        XCTAssertNil(coordinator.errorMessage)

        // 3) Advance to 45s, then mid-playback failure -> switchToNextVodLine carries 45s seek
        engine.emitTick(token: tok2, posMs: 45_000, durMs: 1_800_000)
        engine.emitFailed(token: tok2, message: "播放中途断流")
        XCTAssertTrue(coordinator.errorIsPlaybackFailure)
        XCTAssertEqual(coordinator.errorMessage, "播放中途断流")

        XCTAssertTrue(coordinator.switchToNextVodLine())
        try await waitUntil { engine.loadCalls.count == 3 }
        XCTAssertEqual(coordinator.target.lineIndex, 1)
        XCTAssertEqual(coordinator.target.episodeIndex, 0)
        XCTAssertEqual(engine.loadCalls[2].url.absoluteString, "https://cdn.example/backup_ep_a.m3u8")
        XCTAssertEqual(engine.loadCalls[2].initialSeekMs, 45_000)
        XCTAssertNil(coordinator.errorMessage)
    }

    // MARK: - Item 4: Live TV Same-Channel Line Switch (Line 1 Fails -> Line 2 Succeeds)

    @MainActor
    func testLiveSameChannelLineSwitchFirstFailsSecondSucceeds() async throws {
        let ch1 = LiveChannel(
            name: "CCTV-1 综合",
            group: "央视",
            urls: [
                "https://cdn.example/live/cctv1_line1.m3u8",
                "https://cdn.example/live/cctv1_line2.m3u8",
            ],
            streams: [
                CmsEpisode(name: "线路 1", url: "https://cdn.example/live/cctv1_line1.m3u8"),
                CmsEpisode(name: "线路 2", url: "https://cdn.example/live/cctv1_line2.m3u8"),
            ]
        )
        let ch2 = LiveChannel(
            name: "CCTV-5 体育",
            group: "央视",
            urls: ["https://cdn.example/live/cctv5_line1.m3u8"],
            streams: [
                CmsEpisode(name: "线路 1", url: "https://cdn.example/live/cctv5_line1.m3u8"),
            ]
        )
        let liveSite = CmsSite(key: "__live__", name: "电视直播", type: 1, api: "")
        let liveVideo = CmsVideo(
            id: ch1.id,
            title: ch1.name,
            remarks: ch1.group,
            lines: [CmsLine(name: ch1.group, episodes: ch1.episodes)]
        )
        let engine = MockPlaybackEngineAdapter()

        let coordinator = PlaybackSessionCoordinator(
            initialTarget: PlaybackTargetDescriptor(
                site: liveSite,
                video: liveVideo,
                lineIndex: 0,
                episodeIndex: 0,
                isLiveStream: true,
                liveFlatChannels: [ch1, ch2],
                liveChannelIndex: 0
            ),
            engine: engine,
            resolver: { descriptor in
                let ep = descriptor.currentEpisode!
                if ep.url.contains("line1") {
                    throw MarcoError.networkFailure("直播线路 1 连接超时")
                }
                return ResolvedPlayback(
                    originalUrl: ep.url,
                    playableUrl: URL(string: ep.url)!,
                    isProxied: false,
                    kernelLabel: "AVKit 硬解",
                    resolutionBadge: "直播"
                )
            },
            progressRecorder: { _, _, _ in }
        )

        // Line 1 fails during resolution
        coordinator.startInitialLoad()
        try await waitUntil { coordinator.errorMessage != nil }
        XCTAssertEqual(coordinator.target.liveChannelIndex, 0)
        XCTAssertEqual(coordinator.target.episodeIndex, 0)
        XCTAssertEqual(coordinator.target.liveLineCount, 2)
        XCTAssertTrue(coordinator.target.hasAlternativeLines)

        // Switch to Line 2 on the SAME channel -> succeeds!
        XCTAssertTrue(coordinator.switchToNextLiveLine())
        try await waitUntil { engine.loadCalls.count == 1 }
        XCTAssertEqual(coordinator.target.liveChannelIndex, 0, "Must stay on CCTV-1")
        XCTAssertEqual(coordinator.target.episodeIndex, 1, "Must switch to Line 2")
        XCTAssertEqual(engine.loadCalls[0].url.absoluteString, "https://cdn.example/live/cctv1_line2.m3u8")
        XCTAssertNil(coordinator.errorMessage)

        // Also test playback failure on Line 2 -> error surfaces cleanly keeping channel fixed
        let tokLive = try XCTUnwrap(engine.activeItemToken)
        engine.emitFailed(token: tokLive, message: "直播解码中断")
        XCTAssertTrue(coordinator.errorIsPlaybackFailure)
        XCTAssertEqual(coordinator.target.liveChannelIndex, 0)
    }

    // MARK: - Item 5: Cross-Site Same-ID (ID 42) Isolation & Disabled Origin Retention

    func testCrossSiteSameIdIsolationAndDisabledOriginRetention() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoBatch2CrossSite_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storage = TvStorageManager(cachesDirectory: tempDir, keychain: InMemoryKeychainStore())

        let rawA = #"{"sites":[{"key":"site_a","name":"站点A","type":1,"api":"https://site-a.example/api.php/provide/vod"}]}"#
        let rawB = #"{"sites":[{"key":"site_b","name":"站点B","type":1,"api":"https://site-b.example/api.php/provide/vod"}]}"#
        _ = try storage.upsertSubscription(
            id: "sub_a",
            name: "来源A",
            url: "https://site-a.example/config.json",
            rawContent: rawA
        )
        _ = try storage.upsertSubscription(
            id: "sub_b",
            name: "来源B",
            url: "https://site-b.example/config.json",
            rawContent: rawB
        )
        storage.updatePreferences { $0.selectedSiteKey = "site_b" }

        let requestedHostsBox = StubCmsLockedBox<[String]>([])
        StubCmsURLProtocol.install { req in
            let url = req.url!
            let host = url.host ?? ""
            requestedHostsBox.withLock { $0.append(host) }
            if host == "site-a.example" {
                let json = #"{"list":[{"vod_id":"42","vod_name":"星际穿越·A站","vod_pic":"https://cdn.example/a42.jpg","vod_remarks":"4K","vod_play_from":"A线","vod_play_url":"正片$https://cdn.example/a42.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if host == "site-b.example" {
                let json = #"{"list":[{"vod_id":"42","vod_name":"盗梦空间·B站","vod_pic":"https://cdn.example/b42.jpg","vod_remarks":"蓝光","vod_play_from":"B线","vod_play_url":"正片$https://cdn.example/b42.m3u8"}]}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubCmsURLProtocol.self]
        let client = CmsClient(session: URLSession(configuration: cfg))

        let vidA = CmsVideo(id: "42", title: "星际穿越·A站", poster: "https://cdn.example/a42.jpg", remarks: "4K")
        let vidB = CmsVideo(id: "42", title: "盗梦空间·B站", poster: "https://cdn.example/b42.jpg", remarks: "蓝光")

        storage.upsertWatchHistory(
            WatchHistoryItem(
                site: "site_a",
                id: vidA.id,
                title: vidA.title,
                poster: vidA.poster,
                line: "A线",
                episode: "正片",
                index: 0,
                position: 90_000,
                duration: 6_000_000,
                updated: 1_710_000_001_000
            )
        )
        storage.upsertWatchHistory(
            WatchHistoryItem(
                site: "site_b",
                id: vidB.id,
                title: vidB.title,
                poster: vidB.poster,
                line: "B线",
                episode: "正片",
                index: 0,
                position: 30_000,
                duration: 5_000_000,
                updated: 1_710_000_002_000
            )
        )
        storage.toggleFavorite(site: "site_a", video: vidA)
        storage.toggleFavorite(site: "site_b", video: vidB)

        // Independent keys for same ID 42 across sites
        XCTAssertEqual(storage.watchHistory().count, 2)
        XCTAssertEqual(Set(storage.watchHistory().map(\.key)), ["site_a\n42", "site_b\n42"])
        XCTAssertEqual(storage.favorites().count, 2)
        XCTAssertEqual(Set(storage.favorites().map(\.key)), ["site_a\n42", "site_b\n42"])

        let merged = storage.mergedConfig()
        let histA = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == "site_a" }))
        let favA = try XCTUnwrap(storage.favorites().first(where: { $0.site == "site_a" }))
        let histB = try XCTUnwrap(storage.watchHistory().first(where: { $0.site == "site_b" }))

        // Resolve A even while activeSite is site_b -> MUST query site-a.example and return A's movie
        let resHistA = try await MediaEntryResolver.resolveWatchHistoryEntry(histA, config: merged, cmsClient: client)
        guard case .ready(let siteAOut, let detailA, let resumeA) = resHistA else {
            return XCTFail("Expected site_a history to resolve cleanly")
        }
        XCTAssertEqual(siteAOut.rawKey, "site_a")
        XCTAssertEqual(siteAOut.key, "sub::sub_a::site_a")
        XCTAssertEqual(detailA.title, "星际穿越·A站")
        XCTAssertEqual(detailA.lines.first?.episodes.first?.url, "https://cdn.example/a42.m3u8")
        XCTAssertEqual(resumeA?.resumePosition, 90_000)

        let resHistB = try await MediaEntryResolver.resolveWatchHistoryEntry(histB, config: merged, cmsClient: client)
        guard case .ready(let siteBOut, let detailB, let resumeB) = resHistB else {
            return XCTFail("Expected site_b history to resolve cleanly")
        }
        XCTAssertEqual(siteBOut.rawKey, "site_b")
        XCTAssertEqual(siteBOut.key, "sub::sub_b::site_b")
        XCTAssertEqual(detailB.title, "盗梦空间·B站")
        XCTAssertEqual(detailB.lines.first?.episodes.first?.url, "https://cdn.example/b42.m3u8")
        XCTAssertEqual(resumeB?.resumePosition, 30_000)

        // Now disable subA -> A's history and favorite MUST stay intact and refuse falling back to site_b!
        _ = try storage.upsertSubscription(
            id: "sub_a",
            name: "来源A",
            url: "https://site-a.example/config.json",
            rawContent: rawA,
            enabled: false
        )
        requestedHostsBox.withLock { $0.removeAll() }
        let disabledConfig = storage.mergedConfig()

        let unavailableHistA = try await MediaEntryResolver.resolveWatchHistoryEntry(histA, config: disabledConfig, cmsClient: client)
        guard case .sourceUnavailable(let missingKey1, let reason1) = unavailableHistA else {
            return XCTFail("Expected site_a history to report unavailable origin instead of querying site_b")
        }
        XCTAssertEqual(missingKey1, "site_a")
        XCTAssertTrue(reason1.contains("恢复"))

        let unavailableFavA = try await MediaEntryResolver.resolveFavoriteEntry(
            favA,
            config: disabledConfig,
            watchHistory: storage.watchHistory(),
            cmsClient: client
        )
        guard case .sourceUnavailable(let missingKey2, _) = unavailableFavA else {
            return XCTFail("Expected site_a favorite to report unavailable origin")
        }
        XCTAssertEqual(missingKey2, "site_a")
        XCTAssertTrue(requestedHostsBox.withLock { $0.isEmpty }, "Must NEVER query site_b when site_a is disabled")

        // Verify records were retained in storage and site_b favorite toggle stays isolated
        XCTAssertEqual(storage.watchHistory().count, 2)
        XCTAssertEqual(storage.favorites().count, 2)
        let stillFavB = storage.toggleFavorite(site: "site_b", video: vidB)
        XCTAssertFalse(stillFavB)
        XCTAssertTrue(storage.isFavorite(site: "site_a", id: "42"), "Unfavoriting site_b/42 must not affect site_a/42")
    }

    // MARK: - Item 5: M3U VOD Watched 60s Resumes After Restart from Continue Watching, History & Favorites

    func testM3uVodWatched60SecondsResumesAfterRestartFromAllThreeEntries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarcoBatch2M3uResume_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sharedKeychain = InMemoryKeychainStore()

        let m3uVodText = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="https://cdn.example/m3u_poster.jpg" group-title="4K电影",沙丘2 M3U点播
        #EXTVLCOPT:http-user-agent=MarcoM3uAgent/1.0
        https://cdn.example/vod/dune2_4k.m3u8
        #EXTINF:-1 tvg-logo="https://cdn.example/m3u_poster2.jpg" group-title="纪录片",地球脉动
        https://cdn.example/vod/planet_earth.m3u8
        """

        // Session 1: Import M3U VOD subscription directly (matching production flow), open from Discover, watch 60s, favorite
        let storage1 = TvStorageManager(cachesDirectory: tempDir, keychain: sharedKeychain)
        _ = try storage1.upsertSubscription(
            name: "M3U精选电影",
            url: "https://m3u.example/movies.m3u",
            rawContent: m3uVodText
        )

        let config1 = storage1.mergedConfig()
        let m3uSite = try XCTUnwrap(config1.publicAvailableSites.first(where: { $0.isM3uVodApi }))
        let client1 = CmsClient()
        let homePayload = try await client1.fetchHome(site: m3uSite)
        let duneMovie = try XCTUnwrap(homePayload.listing.videos.first(where: { $0.title == "沙丘2 M3U点播" }))
        XCTAssertEqual(duneMovie.lines.first?.episodes.first?.url, "https://cdn.example/vod/dune2_4k.m3u8")
        XCTAssertEqual(duneMovie.lines.first?.episodes.first?.headers["User-Agent"], "MarcoM3uAgent/1.0")

        storage1.upsertWatchHistory(
            WatchHistoryItem(
                site: m3uSite.key,
                id: duneMovie.id,
                title: duneMovie.title,
                poster: duneMovie.poster,
                line: duneMovie.lines[0].name,
                episode: duneMovie.lines[0].episodes[0].name,
                index: 0,
                position: 60_000,
                duration: 5_400_000,
                updated: 1_710_000_003_000
            )
        )
        XCTAssertTrue(storage1.toggleFavorite(site: m3uSite.key, video: duneMovie))

        // Session 2: Simulate full Apple TV app restart with fresh TvStorageManager & CmsClient
        let storage2 = TvStorageManager(cachesDirectory: tempDir, keychain: sharedKeychain)
        let config2 = storage2.mergedConfig()
        let client2 = CmsClient()

        let continueWatchingEntry = try XCTUnwrap(storage2.watchHistory().first)
        let historyEntry = try XCTUnwrap(storage2.watchHistory().first(where: { $0.id == duneMovie.id && $0.site == m3uSite.key }))
        let favoriteEntry = try XCTUnwrap(storage2.favorites().first(where: { $0.id == duneMovie.id && $0.site == m3uSite.key }))

        // 1) Continue Watching entry
        let cwRes = try await MediaEntryResolver.resolveWatchHistoryEntry(continueWatchingEntry, config: config2, cmsClient: client2)
        // 2) Watch History entry
        let histRes = try await MediaEntryResolver.resolveWatchHistoryEntry(historyEntry, config: config2, cmsClient: client2)
        // 3) Favorites entry
        let favRes = try await MediaEntryResolver.resolveFavoriteEntry(
            favoriteEntry,
            config: config2,
            watchHistory: storage2.watchHistory(),
            cmsClient: client2
        )

        for (label, result) in [("ContinueWatching", cwRes), ("History", histRes), ("Favorites", favRes)] {
            guard case .ready(let site, let video, let resume) = result else {
                return XCTFail("\(label) failed to recover M3U VOD after restart")
            }
            XCTAssertEqual(site.key, m3uSite.key, "\(label) must resolve original M3U site")
            XCTAssertEqual(video.id, duneMovie.id, "\(label) must recover original video ID")
            XCTAssertEqual(video.title, "沙丘2 M3U点播", "\(label) must recover original title")
            XCTAssertFalse(video.lines.isEmpty, "\(label) must recover non-empty lines for M3U VOD")
            XCTAssertEqual(video.lines[0].episodes.first?.url, "https://cdn.example/vod/dune2_4k.m3u8", "\(label) must recover playable stream URL")
            XCTAssertEqual(video.lines[0].episodes.first?.headers["User-Agent"], "MarcoM3uAgent/1.0", "\(label) must preserve M3U headers")
            XCTAssertEqual(resume?.resumePosition, 60_000, "\(label) must restore exact 60s breakpoint")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        timeoutNs: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNs {
                XCTFail("Timed out waiting for coordinator condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private extension MockPlaybackEngineAdapter {
    func emitPlaybackEventsCheck(tokenA: UInt64, coordinator: PlaybackSessionCoordinator) {
        emitEnded(token: tokenA)
        emitFailed(token: tokenA, message: "late A error")
        XCTAssertEqual(coordinator.activeLoaded?.episodeIndex, 2)
        XCTAssertNil(coordinator.errorMessage)
    }
}

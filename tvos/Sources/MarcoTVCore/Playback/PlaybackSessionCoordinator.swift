// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Combine
import Foundation

/// Immutable identity & playback context for a single VOD episode or Live TV channel/line.
public struct PlaybackTargetDescriptor: Equatable, Hashable, Sendable {
    public var site: CmsSite
    public var video: CmsVideo
    public var lineIndex: Int
    public var episodeIndex: Int
    public var initialSeekMs: Int
    public var isLiveStream: Bool
    public var liveFlatChannels: [LiveChannel]
    public var liveChannelIndex: Int

    public init(
        site: CmsSite,
        video: CmsVideo,
        lineIndex: Int,
        episodeIndex: Int,
        initialSeekMs: Int = 0,
        isLiveStream: Bool = false,
        liveFlatChannels: [LiveChannel] = [],
        liveChannelIndex: Int = 0
    ) {
        self.site = site
        self.video = video
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
        self.initialSeekMs = initialSeekMs
        self.isLiveStream = isLiveStream
        self.liveFlatChannels = liveFlatChannels
        self.liveChannelIndex = liveChannelIndex
    }

    public var currentLine: CmsLine? {
        guard video.lines.indices.contains(lineIndex) else { return nil }
        return video.lines[lineIndex]
    }

    public var currentEpisode: CmsEpisode? {
        guard let line = currentLine, line.episodes.indices.contains(episodeIndex) else { return nil }
        return line.episodes[episodeIndex]
    }

    public var hasAlternativeLines: Bool {
        if isLiveStream {
            return (currentLine?.episodes.count ?? 0) > 1
        }
        return video.lines.count > 1
    }

    public var liveLineCount: Int {
        isLiveStream ? (currentLine?.episodes.count ?? 0) : 0
    }
}

/// Token-scoped playback engine interface binding progress, completion, and failure callbacks
/// strictly to the active playback item so stale callbacks from replaced items are discarded.
@MainActor
public protocol PlaybackEngineAdapterProtocol: AnyObject {
    var activeItemToken: UInt64? { get }
    var currentTimeMs: Int { get }
    var durationMs: Int { get }
    var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)? { get set }
    var onPlaybackEnded: ((_ token: UInt64) -> Void)? { get set }
    var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)? { get set }
    func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float)
    func stopCurrentItem()
    func setPlaybackRate(_ rate: Float)
    func teardown()
}

public typealias PlaybackStreamResolver = @Sendable (
    _ descriptor: PlaybackTargetDescriptor
) async throws -> ResolvedPlayback

public typealias PlaybackProgressRecorder = @MainActor (
    _ descriptor: PlaybackTargetDescriptor,
    _ positionMs: Int,
    _ durationMs: Int
) -> Void

/// Deterministic single-active-item playback coordinator for Apple TV VOD & Live TV.
/// Guarantees:
/// - Stream resolution, player status, progress ticks, end notifications, and item failures are bound to a monotonic item token.
/// - Rapid episode / line / channel switches or player exit cancel previous resolve tasks and drop late responses & callbacks.
/// - Watch progress is only ever persisted against the actually-playing item (never attributed to a newly selected or resolving item).
/// - Outro auto-skip and end-of-item auto-advance trigger at most once per playback item.
/// - Same-channel live line switching keeps the active channel fixed while rotating stream URLs.
@MainActor
public final class PlaybackSessionCoordinator: ObservableObject {
    @Published public private(set) var target: PlaybackTargetDescriptor
    @Published public private(set) var activeLoaded: PlaybackTargetDescriptor?
    @Published public private(set) var isResolving: Bool = true
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var errorIsPlaybackFailure: Bool = false
    @Published public private(set) var activeKernelLabel: String = "AVKit 硬解"
    @Published public private(set) var activeResolutionBadge: String = ""

    public var playbackSpeed: Double
    public var skipIntroSec: Int
    public var skipOutroSec: Int
    public var autoNext: Bool
    public var onTargetTransition: (() -> Void)?

    private let engine: PlaybackEngineAdapterProtocol
    private let resolver: PlaybackStreamResolver
    private let progressRecorder: PlaybackProgressRecorder

    private var nextToken: UInt64 = 0
    private var pendingToken: UInt64?
    private var activeLoadedToken: UInt64?
    private var autoAdvanceConsumedToken: UInt64?
    private var resolveTask: Task<Void, Never>?
    private var isTornDown: Bool = false

    public init(
        initialTarget: PlaybackTargetDescriptor,
        engine: PlaybackEngineAdapterProtocol,
        resolver: @escaping PlaybackStreamResolver,
        progressRecorder: @escaping PlaybackProgressRecorder,
        playbackSpeed: Double = 1.0,
        skipIntroSec: Int = 0,
        skipOutroSec: Int = 0,
        autoNext: Bool = true
    ) {
        self.target = initialTarget
        self.engine = engine
        self.resolver = resolver
        self.progressRecorder = progressRecorder
        self.playbackSpeed = playbackSpeed
        self.skipIntroSec = skipIntroSec
        self.skipOutroSec = skipOutroSec
        self.autoNext = autoNext
        bindEngineCallbacks()
    }

    public func startInitialLoad() {
        guard !isTornDown else { return }
        beginResolveCurrentTarget()
    }

    public func retryCurrent() {
        guard !isTornDown else { return }
        persistActiveProgressIfBound()
        beginResolveCurrentTarget()
    }

    public func switchToEpisode(lineIndex: Int, episodeIndex: Int, seekMs: Int) {
        guard !isTornDown,
              !target.isLiveStream,
              target.video.lines.indices.contains(lineIndex),
              target.video.lines[lineIndex].episodes.indices.contains(episodeIndex)
        else {
            return
        }
        if lineIndex == target.lineIndex
            && episodeIndex == target.episodeIndex
            && errorMessage == nil
            && (isResolving || activeLoaded != nil)
        {
            return
        }

        // Persist breakpoint strictly for the currently playing item BEFORE changing target.
        persistActiveProgressIfBound()
        cancelPendingAndDetachActiveItem()

        var next = target
        next.lineIndex = lineIndex
        next.episodeIndex = episodeIndex
        next.initialSeekMs = seekMs > 0 ? seekMs : (skipIntroSec * 1000)
        target = next
        beginResolveCurrentTarget()
    }

    @discardableResult
    public func switchToNextVodLine() -> Bool {
        guard !isTornDown,
              !target.isLiveStream,
              target.video.lines.count > 1
        else {
            return false
        }
        let nextLineIdx = (target.lineIndex + 1) % target.video.lines.count
        let nextLine = target.video.lines[nextLineIdx]
        guard !nextLine.episodes.isEmpty else { return false }
        let clampedEp = min(max(0, target.episodeIndex), nextLine.episodes.count - 1)
        let carrySeekMs = (activeLoaded != nil && engine.currentTimeMs > 0)
            ? engine.currentTimeMs
            : target.initialSeekMs

        persistActiveProgressIfBound()
        cancelPendingAndDetachActiveItem()

        var next = target
        next.lineIndex = nextLineIdx
        next.episodeIndex = clampedEp
        next.initialSeekMs = carrySeekMs
        target = next
        beginResolveCurrentTarget()
        return true
    }

    public func switchLiveChannel(delta: Int) {
        guard !isTornDown, target.isLiveStream else { return }
        let count = target.liveFlatChannels.count
        guard count > 0 else { return }

        cancelPendingAndDetachActiveItem()

        let nextIdx = (target.liveChannelIndex + delta % count + count) % count
        let nextChannel = target.liveFlatChannels[nextIdx]
        var next = target
        next.liveChannelIndex = nextIdx
        next.video = CmsVideo(
            id: nextChannel.id,
            title: nextChannel.name,
            poster: nextChannel.logo,
            remarks: nextChannel.group,
            lines: [CmsLine(name: nextChannel.group, episodes: nextChannel.episodes)]
        )
        next.lineIndex = 0
        next.episodeIndex = 0
        next.initialSeekMs = 0
        target = next
        beginResolveCurrentTarget()
    }

    /// Switches to a specific stream line (`episodeIndex`) on the SAME live TV channel.
    @discardableResult
    public func switchLiveLine(to streamIndex: Int) -> Bool {
        guard !isTornDown,
              target.isLiveStream,
              let line = target.currentLine,
              line.episodes.indices.contains(streamIndex)
        else {
            return false
        }
        if streamIndex == target.episodeIndex && errorMessage == nil && (isResolving || activeLoaded != nil) {
            return false
        }

        cancelPendingAndDetachActiveItem()

        var next = target
        next.episodeIndex = streamIndex
        next.initialSeekMs = 0
        target = next
        beginResolveCurrentTarget()
        return true
    }

    /// Rotates to the next available stream line on the SAME live TV channel.
    @discardableResult
    public func switchToNextLiveLine() -> Bool {
        guard !isTornDown,
              target.isLiveStream,
              let line = target.currentLine,
              line.episodes.count > 1
        else {
            return false
        }
        let nextIndex = (target.episodeIndex + 1) % line.episodes.count
        return switchLiveLine(to: nextIndex)
    }

    public func applyPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if !target.isLiveStream {
            engine.setPlaybackRate(Float(speed))
        }
    }

    public func persistActiveProgressIfBound(explicitPosMs: Int? = nil, explicitDurMs: Int? = nil) {
        guard !isTornDown,
              let activeDesc = activeLoaded,
              !activeDesc.isLiveStream,
              activeLoadedToken != nil
        else {
            return
        }
        let pos = explicitPosMs ?? engine.currentTimeMs
        let dur = explicitDurMs ?? engine.durationMs
        guard pos > 0 else { return }
        progressRecorder(activeDesc, pos, dur)
    }

    public func teardownAndPersist() {
        guard !isTornDown else { return }
        persistActiveProgressIfBound()
        isTornDown = true
        resolveTask?.cancel()
        resolveTask = nil
        pendingToken = nil
        activeLoadedToken = nil
        activeLoaded = nil
        isResolving = false
        engine.teardown()
    }

    // MARK: - Internal Token-Bound State Transitions

    private func bindEngineCallbacks() {
        engine.onProgressTick = { [weak self] token, posMs, durMs in
            self?.handleProgressTick(token: token, posMs: posMs, durMs: durMs)
        }
        engine.onPlaybackEnded = { [weak self] token in
            self?.handlePlaybackEnded(token: token)
        }
        engine.onPlaybackFailed = { [weak self] token, message in
            self?.handlePlaybackFailed(token: token, message: message)
        }
    }

    private func cancelPendingAndDetachActiveItem() {
        resolveTask?.cancel()
        resolveTask = nil
        pendingToken = nil
        activeLoadedToken = nil
        activeLoaded = nil
        autoAdvanceConsumedToken = nil
        engine.stopCurrentItem()
    }

    private func beginResolveCurrentTarget() {
        guard !isTornDown else { return }
        cancelPendingAndDetachActiveItem()

        let descriptor = target
        guard descriptor.currentLine != nil, descriptor.currentEpisode != nil else {
            errorIsPlaybackFailure = false
            errorMessage = "未找到有效的剧集线路"
            isResolving = false
            return
        }

        nextToken &+= 1
        let requestToken = nextToken
        pendingToken = requestToken
        isResolving = true
        errorMessage = nil
        errorIsPlaybackFailure = false
        onTargetTransition?()

        let streamResolver = self.resolver
        resolveTask = Task { @MainActor [weak self] in
            do {
                let resolved = try await streamResolver(descriptor)
                guard let self = self,
                      !Task.isCancelled,
                      !self.isTornDown,
                      self.pendingToken == requestToken
                else {
                    return
                }
                self.pendingToken = nil
                self.activeLoadedToken = requestToken
                self.activeLoaded = descriptor
                self.autoAdvanceConsumedToken = nil
                self.activeKernelLabel = resolved.kernelLabel
                self.activeResolutionBadge = resolved.resolutionBadge
                self.errorMessage = nil
                self.errorIsPlaybackFailure = false
                self.isResolving = false
                let rate = descriptor.isLiveStream ? Float(1.0) : Float(self.playbackSpeed)
                self.engine.load(
                    token: requestToken,
                    url: resolved.playableUrl,
                    initialSeekMs: descriptor.initialSeekMs,
                    rate: rate
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self = self,
                      !Task.isCancelled,
                      !self.isTornDown,
                      self.pendingToken == requestToken
                else {
                    return
                }
                self.pendingToken = nil
                self.activeLoadedToken = nil
                self.activeLoaded = nil
                self.errorIsPlaybackFailure = false
                self.errorMessage = error.localizedDescription
                self.isResolving = false
            }
        }
    }

    private func handleProgressTick(token: UInt64, posMs: Int, durMs: Int) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token,
              let activeDesc = activeLoaded
        else {
            return
        }
        if !activeDesc.isLiveStream && posMs > 0 {
            progressRecorder(activeDesc, posMs, durMs)
        }

        let outroMs = skipOutroSec * 1000
        if !activeDesc.isLiveStream,
           outroMs > 0,
           durMs > outroMs + 30_000,
           posMs >= durMs - outroMs
        {
            triggerAutoAdvanceOnce(forToken: token, posMs: posMs, durMs: durMs)
        }
    }

    private func handlePlaybackEnded(token: UInt64) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token
        else {
            return
        }
        triggerAutoAdvanceOnce(
            forToken: token,
            posMs: engine.currentTimeMs,
            durMs: engine.durationMs
        )
    }

    private func handlePlaybackFailed(token: UInt64, message: String) {
        guard !isTornDown,
              let activeTok = activeLoadedToken,
              activeTok == token
        else {
            return
        }
        // Preserve progress up to the failure point so Retry / Switch Line resumes smoothly.
        let failedPosMs = engine.currentTimeMs
        if !target.isLiveStream && failedPosMs > 0 {
            target.initialSeekMs = failedPosMs
        }
        persistActiveProgressIfBound()
        engine.stopCurrentItem()
        activeLoadedToken = nil
        activeLoaded = nil
        isResolving = false
        errorIsPlaybackFailure = true
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = clean.isEmpty ? "视频加载或播放中断" : clean
    }

    private func triggerAutoAdvanceOnce(forToken token: UInt64, posMs: Int, durMs: Int) {
        guard autoAdvanceConsumedToken != token,
              let activeDesc = activeLoaded,
              !activeDesc.isLiveStream
        else {
            return
        }
        autoAdvanceConsumedToken = token
        persistActiveProgressIfBound(explicitPosMs: posMs, explicitDurMs: durMs)

        guard autoNext,
              let line = activeDesc.currentLine,
              activeDesc.episodeIndex + 1 < line.episodes.count
        else {
            return
        }

        cancelPendingAndDetachActiveItem()
        var next = activeDesc
        next.episodeIndex = activeDesc.episodeIndex + 1
        next.initialSeekMs = skipIntroSec * 1000
        target = next
        beginResolveCurrentTarget()
    }
}

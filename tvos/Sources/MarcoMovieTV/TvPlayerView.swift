// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import AVKit
import Combine
import MarcoTVCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct PlayerMediaTrackOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let index: Int

    public init(id: String, label: String, index: Int) {
        self.id = id
        self.label = label
        self.index = index
    }
}

/// Pluggable media player engine protocol unifying native `AVPlayer` and 6-worker `NetdiskRangeProxyServer` playback.
@MainActor
public protocol PlayerEngineProtocol: AnyObject {
    var currentTimeMs: Int { get }
    var durationMs: Int { get }
    func load(url: URL, initialSeekMs: Int, rate: Float)
    func play()
    func pause()
    func seek(toMs milliseconds: Int)
    func setPlaybackRate(_ rate: Float)
    func teardown()
}

@MainActor
public final class AVKitPlayerEngine: ObservableObject, PlayerEngineProtocol {
    public let avPlayer = AVPlayer()

    @Published public private(set) var audioTracks: [PlayerMediaTrackOption] = []
    @Published public private(set) var selectedAudioId: String = ""
    @Published public private(set) var subtitleTracks: [PlayerMediaTrackOption] = []
    @Published public private(set) var selectedSubtitleId: String = "off"
    @Published public private(set) var detectedVideoBadge: String = ""

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var trackLoadTask: Task<Void, Never>?
    private var pendingRate: Float = 1.0

    public var onProgressTick: ((_ positionMs: Int, _ durationMs: Int) -> Void)?
    public var onPlaybackEnded: (() -> Void)?

    public init() {
        let interval = CMTime(seconds: 5.0, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.onProgressTick?(strongSelf.currentTimeMs, strongSelf.durationMs)
            }
        }
    }

    public var currentTimeMs: Int {
        let sec = CMTimeGetSeconds(avPlayer.currentTime())
        guard sec.isFinite && sec > 0 else { return 0 }
        return Int(sec * 1000.0)
    }

    public var durationMs: Int {
        guard let item = avPlayer.currentItem else { return 0 }
        let sec = CMTimeGetSeconds(item.duration)
        guard sec.isFinite && sec > 0 else { return 0 }
        return Int(sec * 1000.0)
    }

    public func load(url: URL, initialSeekMs: Int, rate: Float) {
        trackLoadTask?.cancel()
        trackLoadTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        audibleGroup = nil
        legibleGroup = nil
        audioTracks = []
        selectedAudioId = ""
        subtitleTracks = []
        selectedSubtitleId = "off"
        detectedVideoBadge = ""
        pendingRate = rate

        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPlaybackEnded?()
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .readyToPlay else { return }
            Task { @MainActor [weak self] in
                guard let strongSelf = self, let readyItem = strongSelf.avPlayer.currentItem else { return }
                strongSelf.updateNaturalSizeBadge(from: readyItem)
                strongSelf.discoverMediaSelectionTracks()
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        discoverMediaSelectionTracks()

        if initialSeekMs > 0 {
            let target = CMTime(value: CMTimeValue(initialSeekMs), timescale: 1000)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.play()
                }
            }
        } else {
            play()
        }
    }

    public func selectAudioTrack(_ track: PlayerMediaTrackOption) {
        guard let item = avPlayer.currentItem,
              let group = audibleGroup,
              track.index >= 0,
              track.index < group.options.count
        else {
            return
        }
        item.select(group.options[track.index], in: group)
        selectedAudioId = track.id
    }

    public func selectSubtitleTrack(_ track: PlayerMediaTrackOption) {
        guard let item = avPlayer.currentItem, let group = legibleGroup else { return }
        if track.index < 0 {
            item.select(nil, in: group)
            selectedSubtitleId = "off"
        } else if track.index < group.options.count {
            item.select(group.options[track.index], in: group)
            selectedSubtitleId = track.id
        }
    }

    public func play() {
        avPlayer.playImmediately(atRate: pendingRate)
    }

    public func pause() {
        avPlayer.pause()
    }

    public func seek(toMs milliseconds: Int) {
        let target = CMTime(value: CMTimeValue(max(0, milliseconds)), timescale: 1000)
        avPlayer.seek(to: target)
    }

    public func setPlaybackRate(_ rate: Float) {
        pendingRate = rate
        if avPlayer.timeControlStatus == .playing {
            avPlayer.rate = rate
        }
    }

    public func teardown() {
        avPlayer.pause()
        trackLoadTask?.cancel()
        trackLoadTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let obs = timeObserver {
            avPlayer.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        avPlayer.replaceCurrentItem(with: nil)
    }

    private func updateNaturalSizeBadge(from item: AVPlayerItem) {
        let size = item.presentationSize
        guard size.width > 0 && size.height > 0 else { return }
        let maxEdge = max(size.width, size.height)
        if maxEdge >= 3200 {
            detectedVideoBadge = "4K"
        } else if maxEdge >= 2200 {
            detectedVideoBadge = "2K"
        } else if maxEdge >= 1800 {
            detectedVideoBadge = "1080P"
        } else if maxEdge >= 1200 {
            detectedVideoBadge = "720P"
        }
    }

    private func discoverMediaSelectionTracks() {
        trackLoadTask?.cancel()
        trackLoadTask = Task { [weak self] in
            guard let initialItem = self?.avPlayer.currentItem else { return }
            let asset = initialItem.asset
            let loadedAudible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let loadedLegible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled,
                  let strongSelf = self,
                  let currentItem = strongSelf.avPlayer.currentItem,
                  currentItem === initialItem
            else {
                return
            }

            if let audGroup = loadedAudible, !audGroup.options.isEmpty {
                strongSelf.audibleGroup = audGroup
                let builtAudio = audGroup.options.enumerated().map { idx, opt in
                    let title = opt.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return PlayerMediaTrackOption(
                        id: "aud_\(idx)",
                        label: title.isEmpty ? "音轨 \(idx + 1)" : title,
                        index: idx
                    )
                }
                strongSelf.audioTracks = builtAudio
                if let currentOpt = currentItem.currentMediaSelection.selectedMediaOption(in: audGroup),
                   let currentIdx = audGroup.options.firstIndex(of: currentOpt)
                {
                    strongSelf.selectedAudioId = "aud_\(currentIdx)"
                } else if let first = builtAudio.first {
                    strongSelf.selectedAudioId = first.id
                }
            }

            if let legGroup = loadedLegible, !legGroup.options.isEmpty {
                strongSelf.legibleGroup = legGroup
                var builtSubs: [PlayerMediaTrackOption] = [
                    PlayerMediaTrackOption(id: "off", label: "关闭字幕", index: -1),
                ]
                for (idx, opt) in legGroup.options.enumerated() {
                    let title = opt.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    builtSubs.append(
                        PlayerMediaTrackOption(
                            id: "sub_\(idx)",
                            label: title.isEmpty ? "字幕 \(idx + 1)" : title,
                            index: idx
                        )
                    )
                }
                strongSelf.subtitleTracks = builtSubs
                if let currentOpt = currentItem.currentMediaSelection.selectedMediaOption(in: legGroup),
                   let currentIdx = legGroup.options.firstIndex(of: currentOpt)
                {
                    strongSelf.selectedSubtitleId = "sub_\(currentIdx)"
                } else {
                    strongSelf.selectedSubtitleId = "off"
                }
            }
        }
    }
}

#if os(tvOS)
private struct NativeTvOSPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let subtitle: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.speeds = [
            AVPlaybackSpeed(rate: 0.75, localizedName: "0.75x"),
            AVPlaybackSpeed(rate: 1.0, localizedName: "1.0x"),
            AVPlaybackSpeed(rate: 1.25, localizedName: "1.25x"),
            AVPlaybackSpeed(rate: 1.5, localizedName: "1.5x"),
            AVPlaybackSpeed(rate: 2.0, localizedName: "2.0x"),
        ]
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
#endif

public struct TvPlayerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentSession: ActivePlaybackSession
    @StateObject private var engine = AVKitPlayerEngine()
    @State private var isResolvingStream = true
    @State private var playbackError: String?
    @State private var selectedSpeed: Double = 1.0
    @State private var showHudBanner = false
    @State private var activeKernelLabel: String = "AVKit 硬解"
    @State private var activeResolutionBadge: String = ""
    @State private var showNetdiskAuthSheet = false

    private let speedChoices: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    public init(session: ActivePlaybackSession) {
        self._currentSession = State(initialValue: session)
    }

    private var currentLine: CmsLine? {
        guard currentSession.video.lines.indices.contains(currentSession.lineIndex) else { return nil }
        return currentSession.video.lines[currentSession.lineIndex]
    }

    private var currentEpisode: CmsEpisode? {
        guard let line = currentLine, line.episodes.indices.contains(currentSession.episodeIndex) else { return nil }
        return line.episodes[currentSession.episodeIndex]
    }

    private var displayResolutionBadge: String {
        !activeResolutionBadge.isEmpty ? activeResolutionBadge : engine.detectedVideoBadge
    }

    private var currentAudioLabel: String {
        engine.audioTracks.first(where: { $0.id == engine.selectedAudioId })?.label ?? "音轨"
    }

    private var currentSubtitleLabel: String {
        engine.subtitleTracks.first(where: { $0.id == engine.selectedSubtitleId })?.label ?? "字幕"
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            #if os(tvOS)
            NativeTvOSPlayerRepresentable(
                player: engine.avPlayer,
                title: currentSession.video.title,
                subtitle: currentEpisode?.name ?? ""
            )
            .ignoresSafeArea()
            #else
            VideoPlayer(player: engine.avPlayer)
                .ignoresSafeArea()
            #endif

            if isResolvingStream {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在准备「\(currentSession.video.title)」\(currentEpisode.map { " · \($0.name)" } ?? "")…")
                        .font(.callout)
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = playbackError {
                VStack(spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.yellow)
                    Text("播放地址解析失败：\(err)")
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        if err.contains("扫码") || (currentLine?.isNetdiskLine == true) {
                            Button("扫码授权 4K 网盘") {
                                if let key = currentLine?.netdiskDriveKey {
                                    appModel.selectedNetdiskDriveKey = key
                                }
                                showNetdiskAuthSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(TvTheme.accent)
                        }

                        Button("重试") {
                            Task { await loadCurrentEpisodeStream() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("关闭播放器") {
                            persistProgressAndDismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(36)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showHudBanner {
                hudBannerView
            }
        }
        .sheet(isPresented: $showNetdiskAuthSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        #if os(tvOS)
        .onMoveCommand { direction in
            guard currentSession.isLiveStream, !currentSession.liveFlatChannels.isEmpty else { return }
            switch direction {
            case .up:
                switchLiveChannel(delta: -1)
            case .down:
                switchLiveChannel(delta: 1)
            default:
                break
            }
        }
        #endif
        .tvExitHandler {
            persistProgressAndDismiss()
        }
        .task {
            selectedSpeed = appModel.preferences.playSpeed
            setIdleTimerDisabled(true)
            configureEngineCallbacks()
            await loadCurrentEpisodeStream()
        }
        .onDisappear {
            persistCurrentProgress()
            engine.teardown()
            setIdleTimerDisabled(false)
        }
    }

    private var hudBannerView: some View {
        HStack(spacing: 14) {
            Text(currentSession.video.title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)

            if let ep = currentEpisode {
                Text(ep.name)
                    .font(.callout)
                    .foregroundColor(TvTheme.secondaryText)
                    .lineLimit(1)
            }

            Text(activeKernelLabel)
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(TvTheme.accent.opacity(0.42))
                .clipShape(Capsule())

            if !displayResolutionBadge.isEmpty {
                Text(displayResolutionBadge)
                    .font(.caption2.bold())
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(TvTheme.gold)
                    .clipShape(Capsule())
            }

            Spacer()

            if engine.audioTracks.count > 1 {
                if #available(tvOS 17.0, *) {
                    Menu("音轨：\(currentAudioLabel)") {
                        ForEach(engine.audioTracks) { opt in
                            Button(opt.label) {
                                engine.selectAudioTrack(opt)
                            }
                        }
                    }
                } else {
                    Button("音轨：\(currentAudioLabel)") {
                        cycleAudioTrack()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if engine.subtitleTracks.count > 1 {
                if #available(tvOS 17.0, *) {
                    Menu("字幕：\(currentSubtitleLabel)") {
                        ForEach(engine.subtitleTracks) { opt in
                            Button(opt.label) {
                                engine.selectSubtitleTrack(opt)
                            }
                        }
                    }
                } else {
                    Button("字幕：\(currentSubtitleLabel)") {
                        cycleSubtitleTrack()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !currentSession.isLiveStream {
                if #available(tvOS 17.0, *) {
                    Menu("倍速 \(String(format: "%.2gx", selectedSpeed))") {
                        ForEach(speedChoices, id: \.self) { sp in
                            Button("\(String(format: "%.2gx", sp))") {
                                applyPlaybackSpeed(sp)
                            }
                        }
                    }
                } else {
                    Button("倍速 \(String(format: "%.2gx", selectedSpeed))") {
                        cyclePlaybackSpeed()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(32)
    }

    private func configureEngineCallbacks() {
        engine.onProgressTick = { posMs, durMs in
            persistCurrentProgress(explicitPosMs: posMs, explicitDurMs: durMs)
            // Auto skip outro if configured
            let outroMs = appModel.preferences.skipOutroSec * 1000
            if !currentSession.isLiveStream,
               outroMs > 0,
               durMs > outroMs + 30_000,
               posMs >= durMs - outroMs
            {
                advanceToNextEpisodeOrFinish()
            }
        }
        engine.onPlaybackEnded = {
            advanceToNextEpisodeOrFinish()
        }
    }

    private func loadCurrentEpisodeStream() async {
        guard let episode = currentEpisode, let line = currentLine else {
            playbackError = "未找到有效的剧集线路"
            isResolvingStream = false
            return
        }
        isResolvingStream = true
        playbackError = nil
        showTransientHud()

        do {
            let resolved = try await appModel.cmsClient.resolvePlayback(
                site: currentSession.site,
                lineName: line.name,
                episode: episode,
                parses: appModel.config.parses,
                proxyServer: appModel.proxyServer,
                storage: appModel.storage,
                rangeProxyServer: appModel.rangeProxyServer,
                isLiveStream: currentSession.isLiveStream
            )
            activeKernelLabel = resolved.kernelLabel
            activeResolutionBadge = resolved.resolutionBadge
            let rate = currentSession.isLiveStream ? Float(1.0) : Float(selectedSpeed)
            engine.load(url: resolved.playableUrl, initialSeekMs: currentSession.initialSeekMs, rate: rate)
            isResolvingStream = false
        } catch {
            playbackError = error.localizedDescription
            isResolvingStream = false
        }
    }

    private func advanceToNextEpisodeOrFinish() {
        guard !currentSession.isLiveStream else { return }
        guard appModel.preferences.autoNext,
              let line = currentLine,
              currentSession.episodeIndex + 1 < line.episodes.count
        else {
            persistCurrentProgress()
            return
        }
        persistCurrentProgress()
        currentSession.episodeIndex += 1
        currentSession.initialSeekMs = appModel.preferences.skipIntroSec * 1000
        Task {
            await loadCurrentEpisodeStream()
        }
    }

    private func switchLiveChannel(delta: Int) {
        let count = currentSession.liveFlatChannels.count
        guard count > 0 else { return }
        let nextIdx = (currentSession.liveChannelIndex + delta + count) % count
        let nextChannel = currentSession.liveFlatChannels[nextIdx]
        currentSession.liveChannelIndex = nextIdx
        currentSession.video = CmsVideo(
            id: nextChannel.id,
            title: nextChannel.name,
            poster: nextChannel.logo,
            remarks: nextChannel.group,
            lines: [CmsLine(name: nextChannel.group, episodes: nextChannel.episodes)]
        )
        currentSession.lineIndex = 0
        currentSession.episodeIndex = 0
        Task {
            await loadCurrentEpisodeStream()
        }
    }

    private func cycleAudioTrack() {
        let tracks = engine.audioTracks
        guard !tracks.isEmpty else { return }
        let idx = tracks.firstIndex(where: { $0.id == engine.selectedAudioId }) ?? 0
        let next = tracks[(idx + 1) % tracks.count]
        engine.selectAudioTrack(next)
    }

    private func cycleSubtitleTrack() {
        let tracks = engine.subtitleTracks
        guard !tracks.isEmpty else { return }
        let idx = tracks.firstIndex(where: { $0.id == engine.selectedSubtitleId }) ?? 0
        let next = tracks[(idx + 1) % tracks.count]
        engine.selectSubtitleTrack(next)
    }

    private func applyPlaybackSpeed(_ sp: Double) {
        selectedSpeed = sp
        engine.setPlaybackRate(Float(sp))
        appModel.updatePlaybackPreferences { $0.playSpeed = sp }
    }

    private func cyclePlaybackSpeed() {
        let currentIdx = speedChoices.firstIndex { abs($0 - selectedSpeed) < 0.01 } ?? 1
        let nextSp = speedChoices[(currentIdx + 1) % speedChoices.count]
        applyPlaybackSpeed(nextSp)
    }

    private func showTransientHud() {
        showHudBanner = true
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            showHudBanner = false
        }
    }

    private func persistCurrentProgress(explicitPosMs: Int? = nil, explicitDurMs: Int? = nil) {
        guard !currentSession.isLiveStream,
              let line = currentLine,
              let episode = currentEpisode
        else { return }
        let pos = explicitPosMs ?? engine.currentTimeMs
        let dur = explicitDurMs ?? engine.durationMs
        guard pos > 0 else { return }
        appModel.recordPlaybackProgress(
            site: currentSession.site,
            video: currentSession.video,
            lineName: line.name,
            episodeName: episode.name,
            episodeIndex: currentSession.episodeIndex,
            positionMs: pos,
            durationMs: dur
        )
    }

    private func persistProgressAndDismiss() {
        persistCurrentProgress()
        dismiss()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

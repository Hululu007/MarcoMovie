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
public final class AVKitPlayerEngine: ObservableObject, PlayerEngineProtocol, PlaybackEngineAdapterProtocol {
    public let avPlayer = AVPlayer()

    @Published public private(set) var audioTracks: [PlayerMediaTrackOption] = []
    @Published public private(set) var selectedAudioId: String = ""
    @Published public private(set) var subtitleTracks: [PlayerMediaTrackOption] = []
    @Published public private(set) var selectedSubtitleId: String = "off"
    @Published public private(set) var detectedVideoBadge: String = ""

    public private(set) var activeItemToken: UInt64?

    private weak var activeItem: AVPlayerItem?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var trackLoadTask: Task<Void, Never>?
    private var pendingRate: Float = 1.0
    private var fallbackTokenCounter: UInt64 = 0

    public var onProgressTick: ((_ token: UInt64, _ positionMs: Int, _ durationMs: Int) -> Void)?
    public var onPlaybackEnded: ((_ token: UInt64) -> Void)?
    public var onPlaybackFailed: ((_ token: UInt64, _ message: String) -> Void)?

    public init() {
        let interval = CMTime(seconds: 5.0, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strongSelf = self,
                      let token = strongSelf.activeItemToken,
                      let item = strongSelf.activeItem,
                      strongSelf.avPlayer.currentItem === item,
                      item.status == .readyToPlay
                else {
                    return
                }
                strongSelf.onProgressTick?(token, strongSelf.currentTimeMs, strongSelf.durationMs)
            }
        }
    }

    public var currentTimeMs: Int {
        guard let item = activeItem, avPlayer.currentItem === item else { return 0 }
        let sec = CMTimeGetSeconds(avPlayer.currentTime())
        guard sec.isFinite && sec > 0 else { return 0 }
        return Int(sec * 1000.0)
    }

    public var durationMs: Int {
        guard let item = activeItem, avPlayer.currentItem === item else { return 0 }
        let sec = CMTimeGetSeconds(item.duration)
        guard sec.isFinite && sec > 0 else { return 0 }
        return Int(sec * 1000.0)
    }

    public func load(url: URL, initialSeekMs: Int, rate: Float) {
        fallbackTokenCounter &+= 1
        load(token: fallbackTokenCounter, url: url, initialSeekMs: initialSeekMs, rate: rate)
    }

    public func load(token: UInt64, url: URL, initialSeekMs: Int, rate: Float) {
        stopCurrentItem()

        pendingRate = rate
        let item = AVPlayerItem(url: url)
        activeItemToken = token
        activeItem = item

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strongSelf = self,
                      strongSelf.activeItemToken == token,
                      strongSelf.activeItem === item
                else {
                    return
                }
                strongSelf.onPlaybackEnded?(token)
            }
        }

        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = err?.localizedDescription ?? "视频播放中断，请重试或切换线路"
            Task { @MainActor [weak self] in
                guard let strongSelf = self,
                      strongSelf.activeItemToken == token,
                      strongSelf.activeItem === item
                else {
                    return
                }
                strongSelf.onPlaybackFailed?(token, message)
            }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let errorMessage = observedItem.error?.localizedDescription ?? "视频资源加载失败，请重试或切换线路"
            Task { @MainActor [weak self] in
                guard let strongSelf = self,
                      strongSelf.activeItemToken == token,
                      strongSelf.activeItem === observedItem,
                      strongSelf.avPlayer.currentItem === observedItem
                else {
                    return
                }
                switch status {
                case .readyToPlay:
                    strongSelf.updateNaturalSizeBadge(from: observedItem)
                    strongSelf.discoverMediaSelectionTracks(for: observedItem, token: token)
                case .failed:
                    strongSelf.onPlaybackFailed?(token, errorMessage)
                default:
                    break
                }
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        discoverMediaSelectionTracks(for: item, token: token)

        if initialSeekMs > 0 {
            let target = CMTime(value: CMTimeValue(initialSeekMs), timescale: 1000)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let strongSelf = self,
                          strongSelf.activeItemToken == token,
                          strongSelf.activeItem === item
                    else {
                        return
                    }
                    strongSelf.play()
                }
            }
        } else {
            play()
        }
    }

    public func stopCurrentItem() {
        avPlayer.pause()
        trackLoadTask?.cancel()
        trackLoadTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        if let failObs = failedToEndObserver {
            NotificationCenter.default.removeObserver(failObs)
            failedToEndObserver = nil
        }
        activeItemToken = nil
        activeItem = nil
        audibleGroup = nil
        legibleGroup = nil
        audioTracks = []
        selectedAudioId = ""
        subtitleTracks = []
        selectedSubtitleId = "off"
        detectedVideoBadge = ""
        avPlayer.replaceCurrentItem(with: nil)
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
        stopCurrentItem()
        if let obs = timeObserver {
            avPlayer.removeTimeObserver(obs)
            timeObserver = nil
        }
        onProgressTick = nil
        onPlaybackEnded = nil
        onPlaybackFailed = nil
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

    private func discoverMediaSelectionTracks(for initialItem: AVPlayerItem, token: UInt64) {
        trackLoadTask?.cancel()
        trackLoadTask = Task { [weak self] in
            let asset = initialItem.asset
            let loadedAudible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let loadedLegible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled,
                  let strongSelf = self,
                  strongSelf.activeItemToken == token,
                  strongSelf.activeItem === initialItem,
                  strongSelf.avPlayer.currentItem === initialItem
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
                if let currentOpt = initialItem.currentMediaSelection.selectedMediaOption(in: audGroup),
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
                if let currentOpt = initialItem.currentMediaSelection.selectedMediaOption(in: legGroup),
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
    let isLiveStream: Bool
    let hasEpisodePicker: Bool
    let vodLineNames: [String]
    let activeVodLineIndex: Int
    let liveLineCount: Int
    let activeLiveLineIndex: Int
    let onOpenEpisodeSelection: () -> Void
    let onSelectVodLine: (Int) -> Void
    let onSelectLiveLine: (Int) -> Void

    final class Coordinator: NSObject {
        var onOpenEpisodeSelection: () -> Void
        var onSelectVodLine: (Int) -> Void
        var onSelectLiveLine: (Int) -> Void
        var lastMenuSignature: String = ""
        weak var lastMetadataItem: AVPlayerItem?
        var lastMetadataSignature: String = ""

        init(
            onOpenEpisodeSelection: @escaping () -> Void,
            onSelectVodLine: @escaping (Int) -> Void,
            onSelectLiveLine: @escaping (Int) -> Void
        ) {
            self.onOpenEpisodeSelection = onOpenEpisodeSelection
            self.onSelectVodLine = onSelectVodLine
            self.onSelectLiveLine = onSelectLiveLine
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onOpenEpisodeSelection: onOpenEpisodeSelection,
            onSelectVodLine: onSelectVodLine,
            onSelectLiveLine: onSelectLiveLine
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.speeds = [
            AVPlaybackSpeed(rate: 0.75, localizedName: "0.75x"),
            AVPlaybackSpeed(rate: 1.0, localizedName: "1.0x"),
            AVPlaybackSpeed(rate: 1.25, localizedName: "1.25x"),
            AVPlaybackSpeed(rate: 1.5, localizedName: "1.5x"),
            AVPlaybackSpeed(rate: 2.0, localizedName: "2.0x"),
        ]
        applyTransportMenuItems(to: controller, coordinator: context.coordinator)
        applyExternalMetadataIfNeeded(to: player.currentItem, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onOpenEpisodeSelection = onOpenEpisodeSelection
        context.coordinator.onSelectVodLine = onSelectVodLine
        context.coordinator.onSelectLiveLine = onSelectLiveLine

        if uiViewController.player !== player {
            uiViewController.player = player
        }
        applyTransportMenuItems(to: uiViewController, coordinator: context.coordinator)
        applyExternalMetadataIfNeeded(to: player.currentItem, coordinator: context.coordinator)
    }

    private func applyTransportMenuItems(to controller: AVPlayerViewController, coordinator: Coordinator) {
        let signature = [
            isLiveStream ? "live" : "vod",
            hasEpisodePicker ? "ep" : "noep",
            "\(activeVodLineIndex)",
            vodLineNames.joined(separator: "|"),
            "\(liveLineCount)",
            "\(activeLiveLineIndex)",
        ].joined(separator: "#")
        guard coordinator.lastMenuSignature != signature else { return }
        coordinator.lastMenuSignature = signature

        var items: [UIMenuElement] = []
        if isLiveStream {
            if liveLineCount > 1 {
                let actions = (0..<liveLineCount).map { idx in
                    UIAction(
                        title: "线路 \(idx + 1)",
                        state: idx == activeLiveLineIndex ? .on : .off
                    ) { _ in
                        coordinator.onSelectLiveLine(idx)
                    }
                }
                let liveMenu = UIMenu(
                    title: "切换线路",
                    image: UIImage(systemName: "arrow.triangle.branch"),
                    children: actions
                )
                items.append(liveMenu)
            }
        } else {
            if hasEpisodePicker {
                let episodeAction = UIAction(
                    title: "选集",
                    image: UIImage(systemName: "square.grid.2x2.fill")
                ) { _ in
                    coordinator.onOpenEpisodeSelection()
                }
                items.append(episodeAction)
            }
            if vodLineNames.count > 1 {
                let lineActions = vodLineNames.enumerated().map { idx, name in
                    UIAction(
                        title: name,
                        state: idx == activeVodLineIndex ? .on : .off
                    ) { _ in
                        coordinator.onSelectVodLine(idx)
                    }
                }
                let lineMenu = UIMenu(
                    title: "切换线路",
                    image: UIImage(systemName: "arrow.triangle.branch"),
                    children: lineActions
                )
                items.append(lineMenu)
            }
        }
        controller.transportBarCustomMenuItems = items
    }

    private func applyExternalMetadataIfNeeded(to item: AVPlayerItem?, coordinator: Coordinator) {
        guard let item = item else { return }
        let metaSig = "\(title)\n\(subtitle)"
        if coordinator.lastMetadataItem === item && coordinator.lastMetadataSignature == metaSig {
            return
        }
        coordinator.lastMetadataItem = item
        coordinator.lastMetadataSignature = metaSig

        var metadata: [AVMetadataItem] = []
        if !title.isEmpty {
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = title as NSString
            titleItem.extendedLanguageTag = "und"
            metadata.append(titleItem)
        }
        if !subtitle.isEmpty {
            let subItem = AVMutableMetadataItem()
            subItem.identifier = .commonIdentifierDescription
            subItem.value = subtitle as NSString
            subItem.extendedLanguageTag = "und"
            metadata.append(subItem)
        }
        item.externalMetadata = metadata
    }
}
#endif

public struct TvPlayerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private let initialSession: ActivePlaybackSession
    @StateObject private var engine = AVKitPlayerEngine()
    @State private var coordinator: PlaybackSessionCoordinator?

    public init(session: ActivePlaybackSession) {
        self.initialSession = session
    }

    public var body: some View {
        Group {
            if let coord = coordinator {
                TvPlayerContentView(
                    coordinator: coord,
                    engine: engine,
                    onDismissRequest: {
                        coord.teardownAndPersist()
                        dismiss()
                    }
                )
                .environmentObject(appModel)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("正在初始化播放器…")
                        .foregroundColor(.white)
                }
            }
        }
        .task {
            setIdleTimerDisabled(true)
            if coordinator == nil {
                let descriptor = PlaybackTargetDescriptor(
                    site: initialSession.site,
                    video: initialSession.video,
                    lineIndex: initialSession.lineIndex,
                    episodeIndex: initialSession.episodeIndex,
                    initialSeekMs: initialSession.initialSeekMs,
                    isLiveStream: initialSession.isLiveStream,
                    liveFlatChannels: initialSession.liveFlatChannels,
                    liveChannelIndex: initialSession.liveChannelIndex
                )
                let cmsClient = appModel.cmsClient
                let parses = appModel.config.parses
                let proxyServer = appModel.proxyServer
                let storage = appModel.storage
                let rangeProxyServer = appModel.rangeProxyServer
                let model = appModel
                let created = PlaybackSessionCoordinator(
                    initialTarget: descriptor,
                    engine: engine,
                    resolver: { target in
                        guard let line = target.currentLine, let episode = target.currentEpisode else {
                            throw MarcoError.invalidFormat("未找到有效的剧集线路")
                        }
                        return try await cmsClient.resolvePlayback(
                            site: target.site,
                            lineName: line.name,
                            episode: episode,
                            parses: parses,
                            proxyServer: proxyServer,
                            storage: storage,
                            rangeProxyServer: rangeProxyServer,
                            isLiveStream: target.isLiveStream
                        )
                    },
                    progressRecorder: { activeDesc, posMs, durMs in
                        guard let line = activeDesc.currentLine, let episode = activeDesc.currentEpisode else { return }
                        model.recordPlaybackProgress(
                            site: activeDesc.site,
                            video: activeDesc.video,
                            lineName: line.name,
                            episodeName: episode.name,
                            episodeIndex: activeDesc.episodeIndex,
                            positionMs: posMs,
                            durationMs: durMs
                        )
                    },
                    playbackSpeed: appModel.preferences.playSpeed,
                    skipIntroSec: appModel.preferences.skipIntroSec,
                    skipOutroSec: appModel.preferences.skipOutroSec,
                    autoNext: appModel.preferences.autoNext
                )
                coordinator = created
                created.startInitialLoad()
            }
        }
        .onDisappear {
            coordinator?.teardownAndPersist()
            setIdleTimerDisabled(false)
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

private struct TvPlayerContentView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @ObservedObject var coordinator: PlaybackSessionCoordinator
    @ObservedObject var engine: AVKitPlayerEngine
    let onDismissRequest: () -> Void

    @State private var selectedSpeed: Double = 1.0
    @State private var showHudBanner = false
    @State private var hudHideTask: Task<Void, Never>?
    @State private var showNetdiskAuthSheet = false
    @State private var showEpisodeSelectionSheet = false
    @State private var pickerLineIndex: Int = 0
    @State private var pickerDescending: Bool = false

    private let speedChoices: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private var currentSession: PlaybackTargetDescriptor {
        coordinator.target
    }

    private var currentLine: CmsLine? {
        currentSession.currentLine
    }

    private var currentEpisode: CmsEpisode? {
        currentSession.currentEpisode
    }

    private var displayResolutionBadge: String {
        !coordinator.activeResolutionBadge.isEmpty ? coordinator.activeResolutionBadge : engine.detectedVideoBadge
    }

    private var currentAudioLabel: String {
        engine.audioTracks.first(where: { $0.id == engine.selectedAudioId })?.label ?? "音轨"
    }

    private var currentSubtitleLabel: String {
        engine.subtitleTracks.first(where: { $0.id == engine.selectedSubtitleId })?.label ?? "字幕"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            #if os(tvOS)
            NativeTvOSPlayerRepresentable(
                player: engine.avPlayer,
                title: currentSession.video.title,
                subtitle: currentEpisode?.name ?? "",
                isLiveStream: currentSession.isLiveStream,
                hasEpisodePicker: !currentSession.isLiveStream && !currentSession.video.lines.isEmpty,
                vodLineNames: currentSession.video.lines.map(\.name),
                activeVodLineIndex: currentSession.lineIndex,
                liveLineCount: currentSession.liveLineCount,
                activeLiveLineIndex: currentSession.episodeIndex,
                onOpenEpisodeSelection: {
                    openEpisodeSelection()
                },
                onSelectVodLine: { lineIdx in
                    guard currentSession.video.lines.indices.contains(lineIdx) else { return }
                    let targetEps = currentSession.video.lines[lineIdx].episodes
                    guard !targetEps.isEmpty else { return }
                    let clampedEp = min(max(0, currentSession.episodeIndex), targetEps.count - 1)
                    let carrySeek = max(engine.currentTimeMs, currentSession.initialSeekMs)
                    coordinator.switchToEpisode(lineIndex: lineIdx, episodeIndex: clampedEp, seekMs: carrySeek)
                },
                onSelectLiveLine: { lineIdx in
                    _ = coordinator.switchLiveLine(to: lineIdx)
                }
            )
            .ignoresSafeArea()
            #else
            VideoPlayer(player: engine.avPlayer)
                .ignoresSafeArea()
            #endif

            if coordinator.isResolving {
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
            } else if let err = coordinator.errorMessage {
                errorOverlayView(errorText: err)
            }

            if showHudBanner {
                hudBannerView
            }
            #if !os(tvOS)
            else if !currentSession.isLiveStream && !currentSession.video.lines.isEmpty && coordinator.errorMessage == nil {
                HStack {
                    Spacer()
                    Button {
                        openEpisodeSelection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("选集")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
                .padding(24)
            }
            #endif
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showNetdiskAuthSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        .fullScreenCover(isPresented: $showEpisodeSelectionSheet) {
            EpisodeSelectionView(
                site: currentSession.site,
                video: currentSession.video,
                selectedLineIndex: $pickerLineIndex,
                descending: $pickerDescending,
                activePlayingLineIndex: currentSession.lineIndex,
                activePlayingEpisodeIndex: currentSession.episodeIndex
            ) { lineIdx, epIdx, resumeMs in
                coordinator.switchToEpisode(lineIndex: lineIdx, episodeIndex: epIdx, seekMs: resumeMs)
            }
            .environmentObject(appModel)
        }
        #else
        .sheet(isPresented: $showNetdiskAuthSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        .sheet(isPresented: $showEpisodeSelectionSheet) {
            EpisodeSelectionView(
                site: currentSession.site,
                video: currentSession.video,
                selectedLineIndex: $pickerLineIndex,
                descending: $pickerDescending,
                activePlayingLineIndex: currentSession.lineIndex,
                activePlayingEpisodeIndex: currentSession.episodeIndex
            ) { lineIdx, epIdx, resumeMs in
                coordinator.switchToEpisode(lineIndex: lineIdx, episodeIndex: epIdx, seekMs: resumeMs)
            }
            .environmentObject(appModel)
            .frame(minWidth: 1120, minHeight: 680)
        }
        #endif
        #if os(tvOS)
        .onMoveCommand { direction in
            guard currentSession.isLiveStream, !currentSession.liveFlatChannels.isEmpty else { return }
            switch direction {
            case .up:
                coordinator.switchLiveChannel(delta: -1)
            case .down:
                coordinator.switchLiveChannel(delta: 1)
            default:
                break
            }
        }
        #endif
        .tvExitHandler {
            onDismissRequest()
        }
        .onAppear {
            selectedSpeed = appModel.preferences.playSpeed
            pickerLineIndex = currentSession.lineIndex
            pickerDescending = appModel.preferences.episodesDescending
            coordinator.onTargetTransition = {
                showTransientHud()
            }
            showTransientHud()
        }
        .onDisappear {
            hudHideTask?.cancel()
            hudHideTask = nil
        }
    }

    private func errorOverlayView(errorText: String) -> some View {
        let prefix = coordinator.errorIsPlaybackFailure ? "播放失败" : "播放地址解析失败"
        let liveLines = currentSession.liveLineCount
        let nextLiveIndex = liveLines > 1 ? ((currentSession.episodeIndex + 1) % liveLines) : 0

        return VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundColor(.yellow)
            Text("\(prefix)：\(errorText)")
                .font(TvFont.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 740)

            HStack(spacing: 14) {
                if errorText.contains("扫码") || (currentLine?.isNetdiskLine == true) {
                    Button("扫码授权 4K 网盘") {
                        if let key = currentLine?.netdiskDriveKey {
                            appModel.selectedNetdiskDriveKey = key
                        }
                        showNetdiskAuthSheet = true
                    }
                    .buttonStyle(TvPillButtonStyle(prominent: true))
                }

                Button("重试") {
                    coordinator.retryCurrent()
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))

                if currentSession.isLiveStream {
                    if liveLines > 1 {
                        Button("切换线路（线路 \(nextLiveIndex + 1)/\(liveLines)）") {
                            _ = coordinator.switchToNextLiveLine()
                        }
                        .buttonStyle(TvPillButtonStyle(prominent: true))
                    }
                    if currentSession.liveFlatChannels.count > 1 {
                        Button("下一频道") {
                            coordinator.switchLiveChannel(delta: 1)
                        }
                        .buttonStyle(TvPillButtonStyle())
                    }
                } else {
                    if currentSession.video.lines.count > 1 {
                        Button("切换下一线路") {
                            _ = coordinator.switchToNextVodLine()
                        }
                        .buttonStyle(TvPillButtonStyle())
                    }
                    if (currentLine?.episodes.count ?? 0) > 1 || currentSession.video.lines.count > 1 {
                        Button("选集 / 换线") {
                            openEpisodeSelection()
                        }
                        .buttonStyle(TvPillButtonStyle())
                    }
                }

                Button("关闭播放器") {
                    onDismissRequest()
                }
                .buttonStyle(TvPillButtonStyle())
            }
        }
        .padding(36)
        .background(TvTheme.surface.opacity(0.92))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(TvTheme.glassStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hudBannerView: some View {
        HStack(spacing: 12) {
            Text(currentSession.video.title)
                .font(TvFont.cardTitle)
                .foregroundColor(.white)
                .lineLimit(1)

            if let ep = currentEpisode {
                Text(ep.name)
                    .font(TvFont.caption)
                    .foregroundColor(TvTheme.secondaryText)
                    .lineLimit(1)
            }

            Text(coordinator.activeKernelLabel)
                .font(TvFont.badge)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(TvTheme.accent.opacity(0.42))
                .clipShape(Capsule())

            if !displayResolutionBadge.isEmpty {
                Text(displayResolutionBadge)
                    .font(TvFont.badge)
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
                    .buttonStyle(TvPillButtonStyle(compact: true))
                } else {
                    Button("音轨：\(currentAudioLabel)") {
                        cycleAudioTrack()
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
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
                    .buttonStyle(TvPillButtonStyle(compact: true))
                } else {
                    Button("字幕：\(currentSubtitleLabel)") {
                        cycleSubtitleTrack()
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
            }

            if currentSession.isLiveStream {
                if currentSession.liveLineCount > 1 {
                    Button {
                        _ = coordinator.switchToNextLiveLine()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 13, weight: .semibold))
                            Text("切换线路 (\(currentSession.episodeIndex + 1)/\(currentSession.liveLineCount))")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
            } else {
                if (currentLine?.episodes.count ?? 0) > 1 || currentSession.video.lines.count > 1 {
                    Button {
                        openEpisodeSelection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("选集")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }

                if #available(tvOS 17.0, *) {
                    Menu("倍速 \(String(format: "%.2gx", selectedSpeed))") {
                        ForEach(speedChoices, id: \.self) { sp in
                            Button("\(String(format: "%.2gx", sp))") {
                                applyPlaybackSpeed(sp)
                            }
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                } else {
                    Button("倍速 \(String(format: "%.2gx", selectedSpeed))") {
                        cyclePlaybackSpeed()
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(TvTheme.surface.opacity(0.90))
        .overlay(Capsule().strokeBorder(TvTheme.glassStroke, lineWidth: 1))
        .clipShape(Capsule())
        .padding(32)
    }

    private func openEpisodeSelection() {
        pickerLineIndex = currentSession.lineIndex
        pickerDescending = appModel.preferences.episodesDescending
        showEpisodeSelectionSheet = true
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
        coordinator.applyPlaybackSpeed(sp)
        appModel.updatePlaybackPreferences { $0.playSpeed = sp }
    }

    private func cyclePlaybackSpeed() {
        let currentIdx = speedChoices.firstIndex { abs($0 - selectedSpeed) < 0.01 } ?? 1
        let nextSp = speedChoices[(currentIdx + 1) % speedChoices.count]
        applyPlaybackSpeed(nextSp)
    }

    private func showTransientHud() {
        hudHideTask?.cancel()
        showHudBanner = true
        hudHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showHudBanner = false
        }
    }
}

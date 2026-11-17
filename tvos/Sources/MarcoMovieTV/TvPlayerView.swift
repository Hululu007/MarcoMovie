// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import AVKit
import Combine
import MarcoTVCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Pluggable media player engine protocol so Phase 1 native `AVPlayer` and Phase 2 `MPVKit` / `KSPlayer`
/// share one unified controller boundary.
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
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var pendingRate: Float = 1.0

    public var onProgressTick: ((_ positionMs: Int, _ durationMs: Int) -> Void)?
    public var onPlaybackEnded: (() -> Void)?

    public init() {
        let interval = CMTime(seconds: 5.0, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.onProgressTick?(self.currentTimeMs, self.durationMs)
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
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        pendingRate = rate
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPlaybackEnded?()
            }
        }
        avPlayer.replaceCurrentItem(with: item)
        if initialSeekMs > 0 {
            let target = CMTime(value: CMTimeValue(initialSeekMs), timescale: 1000)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    self?.play()
                }
            }
        } else {
            play()
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
                HStack(spacing: 16) {
                    Text(currentSession.video.title)
                        .font(.headline)
                        .foregroundColor(.white)
                    if let ep = currentEpisode {
                        Text(ep.name)
                            .font(.callout)
                            .foregroundColor(TvTheme.secondaryText)
                    }
                    Spacer()
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
                proxyServer: appModel.proxyServer
            )
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
            try? await Task.sleep(nanoseconds: 4_000_000_000)
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

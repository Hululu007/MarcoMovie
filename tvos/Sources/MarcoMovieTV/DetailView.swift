// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

/// Full-bleed immersive 10-foot Series Detail page for Apple TV (tvOS 16+).
/// Architecture:
/// - Edge-to-edge hero artwork canvas with ambient theme glaze & multi-layer editorial scrims
/// - Minimal floating top bar, left-anchored cinema Hero Stage with horizontal pill actions
/// - Lower frosted-glass dock housing horizontal play-line pills and a quick-pick episode rail,
///   with one-click entry into the full-screen `EpisodeSelectionView` (`选集页`)
public struct DetailView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public let site: CmsSite
    public let summaryVideo: CmsVideo

    private enum HeroFocusTarget: Hashable {
        case play
    }

    @State private var detailVideo: CmsVideo
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedLineIndex = 0
    @State private var descending = false
    @State private var showEpisodeSelection = false
    @State private var showInlineNetdiskSheet = false
    @State private var synopsisExpanded = false
    @State private var pendingEpisodePlayback: (lineIndex: Int, episodeIndex: Int, resumeMs: Int)?
    @FocusState private var heroFocus: HeroFocusTarget?

    private static let quickRailLimit = 12

    public init(site: CmsSite, summaryVideo: CmsVideo) {
        self.site = site
        self.summaryVideo = summaryVideo
        self._detailVideo = State(initialValue: summaryVideo)
    }

    private var savedHistory: WatchHistoryItem? {
        appModel.watchHistory.first { $0.site == site.key && $0.id == detailVideo.id }
    }

    private var isFav: Bool {
        appModel.favorites.contains { $0.site == site.key && $0.id == detailVideo.id }
    }

    private var safeLineIndex: Int {
        guard !detailVideo.lines.isEmpty else { return 0 }
        return min(max(selectedLineIndex, 0), detailVideo.lines.count - 1)
    }

    private var currentLine: CmsLine? {
        guard detailVideo.lines.indices.contains(safeLineIndex) else { return nil }
        return detailVideo.lines[safeLineIndex]
    }

    private var hasAnyNetdiskLine: Bool {
        detailVideo.lines.contains { $0.isNetdiskLine }
    }

    private var activeUnauthenticatedDrive: (key: String, info: NetdiskDriveInfo)? {
        guard let key = currentLine?.netdiskDriveKey,
              !appModel.loggedInNetdiskDrives.contains(key),
              let info = NetdiskDriveInfo.info(for: key)
        else {
            return nil
        }
        return (key, info)
    }

    private var orderedEpisodes: [(offset: Int, element: CmsEpisode)] {
        guard let eps = currentLine?.episodes else { return [] }
        let indexed = Array(eps.enumerated())
        return descending ? indexed.reversed() : indexed
    }

    private var quickRailEpisodes: [(offset: Int, element: CmsEpisode)] {
        let all = orderedEpisodes
        guard all.count > Self.quickRailLimit else { return all }
        if let hist = savedHistory,
           hist.line == currentLine?.name,
           let pos = all.firstIndex(where: { $0.offset == hist.index })
        {
            let start = max(0, min(pos - 1, all.count - Self.quickRailLimit))
            return Array(all[start..<(start + Self.quickRailLimit)])
        }
        return Array(all.prefix(Self.quickRailLimit))
    }

    private var resumeActionTitle: String {
        if let hist = savedHistory {
            return hist.episode.isEmpty ? "继续观看" : "续播 · \(hist.episode)"
        }
        return "立即播放"
    }

    private var episodeButtonLabel: String {
        let total = currentLine?.episodes.count ?? 0
        if total > 1 {
            return "选集 · 共\(total)集"
        }
        return detailVideo.lines.count > 1 ? "选集与线路" : "选集"
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                floatingTopBar

                Spacer(minLength: activeUnauthenticatedDrive == nil ? 118 : 66)

                editorialHeroStage

                Spacer(minLength: 26)

                lowerCinemaDock
            }
            .frame(maxWidth: .infinity, minHeight: 1002, alignment: .topLeading)
            .padding(.horizontal, 64)
            .padding(.top, 40)
            .padding(.bottom, 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            TvImmersiveArtworkBackdrop(
                posterUrl: detailVideo.poster,
                headers: site.headers,
                themeId: appModel.preferences.ambientTheme,
                intensity: appModel.preferences.ambientIntensity
            )
        )
        #if os(tvOS)
        .fullScreenCover(isPresented: $showEpisodeSelection, onDismiss: flushPendingEpisodePlayback) {
            EpisodeSelectionView(
                site: site,
                video: detailVideo,
                selectedLineIndex: $selectedLineIndex,
                descending: $descending
            ) { lineIdx, epIdx, resumeMs in
                pendingEpisodePlayback = (lineIdx, epIdx, resumeMs)
            }
            .environmentObject(appModel)
        }
        .fullScreenCover(isPresented: $showInlineNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        #else
        .sheet(isPresented: $showEpisodeSelection, onDismiss: flushPendingEpisodePlayback) {
            EpisodeSelectionView(
                site: site,
                video: detailVideo,
                selectedLineIndex: $selectedLineIndex,
                descending: $descending
            ) { lineIdx, epIdx, resumeMs in
                pendingEpisodePlayback = (lineIdx, epIdx, resumeMs)
            }
            .environmentObject(appModel)
            .frame(minWidth: 1120, minHeight: 680)
        }
        .sheet(isPresented: $showInlineNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        #endif
        .task {
            descending = appModel.preferences.episodesDescending
            heroFocus = .play
            await loadFullDetail()
        }
        .tvExitHandler {
            dismiss()
        }
    }

    private var floatingTopBar: some View {
        HStack(alignment: .center, spacing: 18) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                    Text("返回")
                }
            }
            .buttonStyle(TvPillButtonStyle(compact: true))

            Spacer()

            MarcoBrandLogo(iconSize: 38, fontSize: 22)
        }
    }

    private var editorialHeroStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Metadata strip
            HStack(spacing: 10) {
                metaBadge(site.name, highlight: true)
                if let score = detailVideo.doubanScore, score > 0 {
                    Text(String(format: "豆瓣 %.1f", score))
                        .font(TvFont.badge)
                        .foregroundColor(TvTheme.darkInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(TvTheme.gold)
                        .clipShape(Capsule())
                }
                if !detailVideo.year.isEmpty {
                    metaBadge(detailVideo.year)
                }
                if !detailVideo.area.isEmpty {
                    metaBadge(detailVideo.area)
                }
                if !detailVideo.remarks.isEmpty {
                    metaBadge(detailVideo.remarks)
                }
                if currentLine?.isNetdiskLine == true {
                    Text("4K 云盘原画")
                        .font(TvFont.badge)
                        .foregroundColor(TvTheme.gold)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.24))
                        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.60), lineWidth: 1))
                        .clipShape(Capsule())
                }
            }

            // Dramatic Hero Title
            Text(detailVideo.title)
                .font(TvFont.cinemaTitle)
                .foregroundColor(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.65), radius: 18, x: 0, y: 6)

            // Resume progress & Cast line
            if let hist = savedHistory {
                HStack(spacing: 12) {
                    Circle()
                        .fill(TvTheme.accent)
                        .frame(width: 9, height: 9)
                    Text(
                        hist.episode.isEmpty
                            ? "上次观看 · 已看 \(Int(hist.progressFraction * 100))%"
                            : "上次观看 · \(hist.episode) · 已看 \(Int(hist.progressFraction * 100))%"
                    )
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.92))

                    if hist.progressFraction > 0.01 {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 124, height: 5)
                            Capsule()
                                .fill(TvTheme.accent)
                                .frame(width: max(8, 124 * hist.progressFraction), height: 5)
                        }
                    }
                }
            }

            if !detailVideo.actor.isEmpty {
                Text("主演：\(detailVideo.actor)")
                    .font(TvFont.caption)
                    .foregroundColor(Color.white.opacity(0.76))
                    .lineLimit(1)
            }

            if !detailVideo.description.isEmpty {
                Text(detailVideo.description)
                    .font(TvFont.body)
                    .foregroundColor(Color.white.opacity(0.86))
                    .lineSpacing(5)
                    .lineLimit(synopsisExpanded ? 6 : 2)
                    .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 2)
            }

            // Hero Horizontal Action Pill Bar
            HStack(spacing: 16) {
                Button {
                    playPrimaryAction()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text(resumeActionTitle)
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
                .focused($heroFocus, equals: .play)
                .disabled(detailVideo.lines.isEmpty)

                if !detailVideo.lines.isEmpty {
                    Button {
                        showEpisodeSelection = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(episodeButtonLabel)
                        }
                    }
                    .buttonStyle(TvPillButtonStyle())
                }

                Button {
                    appModel.toggleFavorite(site: site, video: detailVideo)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundColor(isFav ? .red : nil)
                        Text(isFav ? "已收藏" : "收藏")
                    }
                }
                .buttonStyle(TvPillButtonStyle(active: isFav))

                if hasAnyNetdiskLine {
                    Button {
                        if let key = currentLine?.netdiskDriveKey {
                            appModel.selectedNetdiskDriveKey = key
                        }
                        showInlineNetdiskSheet = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 15, weight: .semibold))
                            Text("云盘扫码")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle())
                }

                if detailVideo.description.count > 85 {
                    Button {
                        synopsisExpanded.toggle()
                    } label: {
                        Text(synopsisExpanded ? "收起简介" : "更多简介")
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: 1020, alignment: .leading)
    }

    private var lowerCinemaDock: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isLoading && detailVideo.lines.isEmpty {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("正在解析选集与播放线路…")
                        .font(TvFont.body)
                        .foregroundColor(TvTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 44)
            } else if let err = errorMessage, detailVideo.lines.isEmpty {
                HStack(spacing: 18) {
                    Text("详情加载失败：\(err)")
                        .font(TvFont.body)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("重试加载") {
                        Task { await loadFullDetail() }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true))
                }
                .padding(.vertical, 16)
            } else if detailVideo.lines.isEmpty {
                Text("暂无可播放线路")
                    .font(TvFont.body)
                    .foregroundColor(TvTheme.mutedText)
                    .padding(.vertical, 16)
            } else {
                playLineBar

                if let unauth = activeUnauthenticatedDrive {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(TvTheme.gold)
                        Text("当前线路需登录「\(unauth.info.tvName)（\(unauth.info.providerName)）」以启用 6 线程 4K 原画直连")
                            .font(TvFont.caption)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Button("立即扫码登录") {
                            appModel.selectedNetdiskDriveKey = unauth.key
                            showInlineNetdiskSheet = true
                        }
                        .buttonStyle(TvPillButtonStyle(prominent: true, compact: true))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.36), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                quickEpisodeRail
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1.1)
        )
        .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
    }

    private var playLineBar: some View {
        HStack(spacing: 16) {
            Text("播放线路")
                .font(TvFont.cardTitle)
                .foregroundColor(TvTheme.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(detailVideo.lines.enumerated()), id: \.offset) { idx, line in
                        let active = safeLineIndex == idx
                        Button {
                            selectedLineIndex = idx
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(line.name) (\(line.episodes.count))")
                                if line.isNetdiskLine {
                                    Text("4K 云盘")
                                        .font(TvFont.badge)
                                        .foregroundColor(TvTheme.gold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(red: 0.14, green: 0.10, blue: 0.04).opacity(0.82))
                                        .overlay(Capsule().strokeBorder(TvTheme.gold.opacity(0.65), lineWidth: 0.8))
                                        .clipShape(Capsule())
                                } else if line.isM3u8Preferred {
                                    Text("HLS")
                                        .font(TvFont.badge)
                                        .foregroundColor(Color(red: 0.56, green: 0.96, blue: 0.72))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(red: 0.04, green: 0.18, blue: 0.10).opacity(0.82))
                                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.60), lineWidth: 0.8))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .buttonStyle(TvPillButtonStyle(active: active, compact: true))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }

    private var quickEpisodeRail: some View {
        let total = currentLine?.episodes.count ?? 0
        let railItems = quickRailEpisodes
        let isNetdisk = currentLine?.isNetdiskLine ?? false

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("分集")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)

                if let lineName = currentLine?.name {
                    Text("\(lineName) · 共 \(total) 集")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }

                Spacer()

                Button {
                    descending.toggle()
                    appModel.updatePlaybackPreferences { $0.episodesDescending = descending }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text(descending ? "倒序" : "正序")
                    }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))

                Button {
                    showEpisodeSelection = true
                } label: {
                    HStack(spacing: 5) {
                        Text("全部选集")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(railItems, id: \.offset) { item in
                        let isLastPlayed = savedHistory?.index == item.offset
                            && savedHistory?.line == currentLine?.name
                        let progress = isLastPlayed ? (savedHistory?.progressFraction ?? 0) : 0
                        let badge: String? = isLastPlayed
                            ? (progress > 0.01 ? "上次观看 · \(Int(progress * 100))%" : "上次观看")
                            : nil
                        Button {
                            let seek = isLastPlayed ? (savedHistory?.resumePosition ?? 0) : 0
                            appModel.startVodPlayback(
                                site: site,
                                video: detailVideo,
                                lineIndex: safeLineIndex,
                                episodeIndex: item.offset,
                                resumeMs: seek
                            )
                        } label: {
                            TvEpisodeCardContent(
                                episodeNumber: item.offset + 1,
                                title: item.element.name,
                                badgeLabel: badge,
                                subtitle: currentLine?.name,
                                isHighlighted: isLastPlayed,
                                isNetdisk4K: isNetdisk,
                                progressFraction: progress,
                                cardHeight: 112
                            )
                            .frame(width: 284)
                        }
                        .buttonStyle(TvEpisodeTileButtonStyle(active: isLastPlayed, cornerRadius: 18))
                    }

                    if total > railItems.count {
                        Button {
                            showEpisodeSelection = true
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "square.grid.2x2.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                Text("查看全部 \(total) 集")
                                    .font(TvFont.cardTitle)
                            }
                            .frame(width: 224, height: 112)
                        }
                        .buttonStyle(TvEpisodeTileButtonStyle(active: false, cornerRadius: 18))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }

    private func metaBadge(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(TvFont.caption)
            .foregroundColor(highlight ? Color(red: 0.78, green: 0.90, blue: 1.0) : Color.white.opacity(0.90))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(highlight ? TvTheme.accent.opacity(0.28) : Color.white.opacity(0.14))
            .overlay(
                Capsule().strokeBorder(
                    highlight ? TvTheme.accent.opacity(0.65) : Color.white.opacity(0.22),
                    lineWidth: 1
                )
            )
            .clipShape(Capsule())
    }

    private func flushPendingEpisodePlayback() {
        guard let req = pendingEpisodePlayback else { return }
        pendingEpisodePlayback = nil
        appModel.startVodPlayback(
            site: site,
            video: detailVideo,
            lineIndex: req.lineIndex,
            episodeIndex: req.episodeIndex,
            resumeMs: req.resumeMs
        )
    }

    private func playPrimaryAction() {
        guard !detailVideo.lines.isEmpty else { return }
        if let hist = savedHistory,
           let matchedLine = detailVideo.lines.firstIndex(where: { $0.name == hist.line }),
           detailVideo.lines[matchedLine].episodes.indices.contains(hist.index)
        {
            appModel.startVodPlayback(
                site: site,
                video: detailVideo,
                lineIndex: matchedLine,
                episodeIndex: hist.index,
                resumeMs: hist.resumePosition
            )
            return
        }
        appModel.startVodPlayback(site: site, video: detailVideo, lineIndex: safeLineIndex, episodeIndex: 0)
    }

    private func loadFullDetail() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await appModel.cmsClient.fetchDetail(site: site, video: summaryVideo)
            detailVideo = loaded
            if !loaded.poster.isEmpty {
                appModel.backdropPosterUrl = loaded.poster
            }
            if let hist = savedHistory,
               let lIdx = loaded.lines.firstIndex(where: { $0.name == hist.line })
            {
                selectedLineIndex = lIdx
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MARCO_SIM_SCENE"] == "episodes" {
            try? await Task.sleep(nanoseconds: 450_000_000)
            showEpisodeSelection = true
        }
        #endif
    }
}

// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct DetailView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public let site: CmsSite
    public let summaryVideo: CmsVideo

    @State private var detailVideo: CmsVideo
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedLineIndex = 0
    @State private var selectedGroupPage = 0
    @State private var descending = false
    @State private var showInlineNetdiskSheet = false

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

    private var currentLine: CmsLine? {
        guard detailVideo.lines.indices.contains(selectedLineIndex) else { return nil }
        return detailVideo.lines[selectedLineIndex]
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 44) {
            // Left fixed column: Poster + Metadata + Primary Actions
            VStack(alignment: .leading, spacing: 20) {
                RemotePosterView(
                    url: detailVideo.poster,
                    title: detailVideo.title,
                    headers: site.headers,
                    cornerRadius: 20
                )
                .frame(width: 300, height: 440)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let score = detailVideo.doubanScore {
                            Text(String(format: "豆瓣 %.1f", score))
                                .font(.caption.bold())
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(TvTheme.gold)
                                .clipShape(Capsule())
                        }
                        if !detailVideo.year.isEmpty {
                            Text(detailVideo.year)
                                .font(.caption)
                                .foregroundColor(TvTheme.secondaryText)
                        }
                        if !detailVideo.area.isEmpty {
                            Text(detailVideo.area)
                                .font(.caption)
                                .foregroundColor(TvTheme.secondaryText)
                        }
                    }

                    Text("片源：\(site.name)")
                        .font(.caption)
                        .foregroundColor(TvTheme.mutedText)
                }

                VStack(spacing: 14) {
                    Button {
                        playPrimaryAction()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(resumeActionTitle)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TvTheme.accent)
                    .disabled(detailVideo.lines.isEmpty)

                    Button {
                        appModel.toggleFavorite(site: site, video: detailVideo)
                    } label: {
                        HStack {
                            Image(systemName: isFav ? "heart.fill" : "heart")
                                .foregroundColor(isFav ? .red : .white)
                            Text(isFav ? "已收藏" : "加入收藏")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)

                    Button("返回") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(width: 300)
            }

            // Right scrollable column: Synopsis + Play Lines + 50-Episode Groups + Episode Grid
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(detailVideo.title)
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)

                    if !detailVideo.actor.isEmpty {
                        Text("主演：\(detailVideo.actor)")
                            .font(.callout)
                            .foregroundColor(TvTheme.secondaryText)
                            .lineLimit(2)
                    }

                    if !detailVideo.description.isEmpty {
                        Text(detailVideo.description)
                            .font(.callout)
                            .foregroundColor(TvTheme.secondaryText)
                            .lineLimit(5)
                    }

                    if isLoading {
                        ProgressView("正在解析选集线路…")
                            .padding(.vertical, 32)
                    } else if let err = errorMessage {
                        Text("详情加载失败：\(err)")
                            .foregroundColor(.orange)
                    } else if detailVideo.lines.isEmpty {
                        Text("暂无可播放线路")
                            .foregroundColor(TvTheme.mutedText)
                    } else {
                        playLineSelector
                        if let driveKey = currentLine?.netdiskDriveKey,
                           !appModel.loggedInNetdiskDrives.contains(driveKey),
                           let driveInfo = NetdiskDriveInfo.info(for: driveKey)
                        {
                            HStack(spacing: 16) {
                                Image(systemName: "externaldrive.badge.exclamationmark")
                                    .foregroundColor(TvTheme.gold)
                                Text("当前线路需要登录「\(driveInfo.tvName)（\(driveInfo.providerName)）」方可启用 6 线程 4K 原画播放")
                                    .font(.callout)
                                    .foregroundColor(.white)
                                Spacer()
                                Button("立即扫码登录") {
                                    appModel.selectedNetdiskDriveKey = driveKey
                                    showInlineNetdiskSheet = true
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(TvTheme.accent)
                            }
                            .padding(18)
                            .background(TvTheme.elevatedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        episodeGroupToolbar
                        episodeGrid
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(48)
        .background(TvTheme.background)
        .sheet(isPresented: $showInlineNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        .task {
            descending = appModel.preferences.episodesDescending
            await loadFullDetail()
        }
        .tvExitHandler {
            dismiss()
        }
    }

    private var resumeActionTitle: String {
        if let hist = savedHistory {
            return hist.episode.isEmpty ? "继续观看" : "续播 \(hist.episode)"
        }
        return "立即播放"
    }

    private var playLineSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放线路")
                .font(.headline)
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(detailVideo.lines.enumerated()), id: \.offset) { idx, line in
                        let active = selectedLineIndex == idx
                        Button {
                            selectedLineIndex = idx
                            selectedGroupPage = 0
                        } label: {
                            HStack(spacing: 6) {
                                Text(line.name)
                                if line.isNetdiskLine {
                                    Text("4K 云盘")
                                        .font(.caption2.bold())
                                        .foregroundColor(TvTheme.gold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(TvTheme.gold.opacity(0.22))
                                        .clipShape(Capsule())
                                } else if line.isM3u8Preferred {
                                    Text("HLS")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.28))
                                        .clipShape(Capsule())
                                }
                            }
                            .font(.callout.weight(active ? .bold : .regular))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(active ? TvTheme.accent : TvTheme.surface)
                            .clipShape(Capsule())
                        }
                        .tvCardButtonStyle()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var episodeGroupToolbar: some View {
        let total = currentLine?.episodes.count ?? 0
        let pageSize = CmsParser.episodePageSize
        let groupCount = max(1, (total + pageSize - 1) / pageSize)

        return HStack(spacing: 16) {
            Text("选集（共 \(total) 集）")
                .font(.headline)
                .foregroundColor(.white)

            if groupCount > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<groupCount, id: \.self) { gIdx in
                            let startNum = gIdx * pageSize + 1
                            let endNum = min(total, (gIdx + 1) * pageSize)
                            Button {
                                selectedGroupPage = gIdx
                            } label: {
                                Text("\(startNum)-\(endNum)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(selectedGroupPage == gIdx ? TvTheme.accent : TvTheme.surface)
                                    .clipShape(Capsule())
                            }
                            .tvCardButtonStyle()
                        }
                    }
                }
            }

            Spacer()

            Button {
                descending.toggle()
                appModel.updatePlaybackPreferences { $0.episodesDescending = descending }
            } label: {
                Label(descending ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
    }

    private var episodeGrid: some View {
        let allIndexed: [(offset: Int, element: CmsEpisode)] = {
            guard let eps = currentLine?.episodes else { return [] }
            let base = Array(eps.enumerated())
            return descending ? base.reversed() : base
        }()

        let pageSize = CmsParser.episodePageSize
        let start = min(selectedGroupPage * pageSize, allIndexed.count)
        let end = min(start + pageSize, allIndexed.count)
        let slice = Array(allIndexed[start..<end])

        let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)
        return LazyVGrid(columns: cols, spacing: 14) {
            ForEach(slice, id: \.offset) { item in
                let isLastPlayed = savedHistory?.index == item.offset && savedHistory?.line == currentLine?.name
                Button {
                    let seek = isLastPlayed ? (savedHistory?.resumePosition ?? 0) : 0
                    appModel.startVodPlayback(
                        site: site,
                        video: detailVideo,
                        lineIndex: selectedLineIndex,
                        episodeIndex: item.offset,
                        resumeMs: seek
                    )
                } label: {
                    Text(item.element.name)
                        .font(.callout.weight(isLastPlayed ? .bold : .regular))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .background(isLastPlayed ? TvTheme.accent : TvTheme.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .tvCardButtonStyle()
            }
        }
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
        let lineIdx = min(selectedLineIndex, detailVideo.lines.count - 1)
        appModel.startVodPlayback(site: site, video: detailVideo, lineIndex: lineIdx, episodeIndex: 0)
    }

    private func loadFullDetail() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await appModel.cmsClient.fetchDetail(site: site, video: summaryVideo)
            detailVideo = loaded
            if let hist = savedHistory,
               let lIdx = loaded.lines.firstIndex(where: { $0.name == hist.line })
            {
                selectedLineIndex = lIdx
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

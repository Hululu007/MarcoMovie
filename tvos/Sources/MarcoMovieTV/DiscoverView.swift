// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct DiscoverView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private let posterColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 28),
        count: 6
    )

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                headerToolbar

                if !appModel.watchHistory.isEmpty {
                    continueWatchingRail
                }

                if !appModel.categories.isEmpty {
                    categoryCapsulesBar
                }

                if appModel.isLoadingDiscover && appModel.discoverVideos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在加载片单…")
                            .padding(.vertical, 80)
                        Spacer()
                    }
                } else if let err = appModel.discoverError, appModel.discoverVideos.isEmpty {
                    VStack(spacing: 16) {
                        Text("加载失败：\(err)")
                            .foregroundColor(.orange)
                        HStack(spacing: 16) {
                            Button("重试") {
                                Task { await appModel.loadHomeForActiveSite() }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("切换其他片源") {
                                appModel.showSiteSwitcherSheet = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    posterGridWall
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
        }
        .task {
            if appModel.discoverVideos.isEmpty && appModel.activeSite != nil {
                await appModel.loadHomeForActiveSite()
            }
        }
    }

    private var headerToolbar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Marco Movie")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                if let site = appModel.activeSite {
                    Text("当前片源：\(site.name) · 可用 \(appModel.config.availableSites.count)/\(appModel.config.sites.count)")
                        .font(.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }
            }

            Spacer()

            Button {
                appModel.showSiteSwitcherSheet = true
            } label: {
                Label(appModel.activeSite?.name ?? "切换片源", systemImage: "rectangle.stack.badge.play")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)

            Button {
                appModel.openLanQrModal()
            } label: {
                Label("扫码快传", systemImage: "qrcode")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }

    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("继续观看")
                .font(.headline)
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(appModel.watchHistory.prefix(12)) { item in
                        Button {
                            let site = appModel.config.sites.first { $0.key == item.site }
                                ?? appModel.activeSite
                            if let targetSite = site {
                                let stubVideo = CmsVideo(
                                    id: item.id,
                                    title: item.title,
                                    poster: item.poster,
                                    remarks: item.episode
                                )
                                appModel.selectedDetailContext = (targetSite, stubVideo)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomLeading) {
                                    RemotePosterView(url: item.poster, title: item.title, cornerRadius: 14)
                                        .frame(width: 260, height: 148)

                                    GeometryReader { geo in
                                        VStack {
                                            Spacer()
                                            ZStack(alignment: .leading) {
                                                Rectangle()
                                                    .fill(Color.black.opacity(0.55))
                                                    .frame(height: 5)
                                                Rectangle()
                                                    .fill(TvTheme.accent)
                                                    .frame(width: geo.size.width * item.progressFraction, height: 5)
                                            }
                                        }
                                    }
                                    .frame(width: 260, height: 148)
                                }
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .frame(width: 260, alignment: .leading)
                                Text(item.episode.isEmpty ? "继续播放" : item.episode)
                                    .font(.caption2)
                                    .foregroundColor(TvTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .tvCardButtonStyle()
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var categoryCapsulesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                categoryCapsule(id: "", label: "精选推荐")
                ForEach(appModel.categories) { category in
                    categoryCapsule(id: category.id, label: category.name)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func categoryCapsule(id: String, label: String) -> some View {
        let isSelected = appModel.selectedCategoryId == id
        return Button {
            Task { await appModel.selectCategory(id) }
        } label: {
            Text(label)
                .font(.callout.weight(isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .white : TvTheme.secondaryText)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(isSelected ? TvTheme.accent : TvTheme.surface)
                .clipShape(Capsule())
        }
        .tvCardButtonStyle()
    }

    private var posterGridWall: some View {
        VStack(spacing: 24) {
            LazyVGrid(columns: posterColumns, spacing: 36) {
                ForEach(appModel.discoverVideos) { video in
                    Button {
                        if let site = appModel.activeSite {
                            appModel.backdropPosterUrl = video.poster
                            appModel.selectedDetailContext = (site, video)
                        }
                    } label: {
                        PosterCardCell(
                            video: video,
                            headers: appModel.activeSite?.headers ?? [:]
                        )
                    }
                    .tvCardButtonStyle()
                    .task {
                        await appModel.loadMoreDiscoverIfNeeded(currentVideo: video)
                    }
                }
            }

            if appModel.isLoadingMore {
                ProgressView()
                    .padding(.vertical, 24)
            }
        }
    }
}

public struct PosterCardCell: View {
    public let video: CmsVideo
    public let headers: [String: String]

    public init(video: CmsVideo, headers: [String: String] = [:]) {
        self.video = video
        self.headers = headers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RemotePosterView(
                    url: video.poster,
                    title: video.title,
                    headers: headers,
                    cornerRadius: 16
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit)

                if let score = video.doubanScore {
                    Text(String(format: "%.1f", score))
                        .font(.caption2.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TvTheme.gold)
                        .clipShape(Capsule())
                        .padding(10)
                } else if !video.remarks.isEmpty {
                    Text(video.remarks)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(10)
                }
            }

            Text(video.title)
                .font(.callout.weight(.medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
    }
}

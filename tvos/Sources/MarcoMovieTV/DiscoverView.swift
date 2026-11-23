// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct DiscoverView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum DiscoverFocusTarget: Hashable {
        case continueWatching(String)
        case poster(String)
    }

    @State private var lastOpenedFocus: DiscoverFocusTarget?
    @FocusState private var focusedCard: DiscoverFocusTarget?

    private let posterColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 26),
        count: 6
    )

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                discoverTopToolbar

                if !appModel.watchHistory.isEmpty {
                    continueWatchingRail
                }

                if appModel.isLoadingDiscover && appModel.discoverVideos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("正在加载片单…")
                            .font(TvFont.body)
                            .padding(.vertical, 80)
                        Spacer()
                    }
                } else if let err = appModel.discoverError, appModel.discoverVideos.isEmpty {
                    VStack(spacing: 16) {
                        Text("加载失败：\(err)")
                            .font(TvFont.body)
                            .foregroundColor(.orange)
                        HStack(spacing: 16) {
                            Button("重试") {
                                Task { await appModel.loadHomeForActiveSite() }
                            }
                            .buttonStyle(TvPillButtonStyle(prominent: true))

                            Button("切换其他片源") {
                                appModel.showSiteSwitcherSheet = true
                            }
                            .buttonStyle(TvPillButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    posterGridWall
                }
            }
            .padding(.horizontal, 56)
            .padding(.top, 12)
            .padding(.bottom, 48)
        }
        .task {
            if appModel.discoverVideos.isEmpty && appModel.activeSite != nil {
                await appModel.loadHomeForActiveSite()
            }
        }
        .onChange(of: appModel.selectedDetailContext == nil) { isClosed in
            guard isClosed else { return }
            restoreLastOpenedCardFocus()
        }
    }

    private func restoreLastOpenedCardFocus() {
        var available: [DiscoverFocusTarget] = appModel.watchHistory.prefix(12).map { .continueWatching($0.key) }
        available.append(contentsOf: appModel.discoverVideos.map { .poster($0.id) })
        guard let target = FocusRestorationPlanner.resolvePosterCardReturn(
            lastOpenedKey: lastOpenedFocus,
            availableKeys: available
        ) else {
            return
        }
        focusedCard = target
        DispatchQueue.main.async {
            self.focusedCard = target
        }
    }

    private var discoverTopToolbar: some View {
        HStack(spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    categoryCapsule(id: "", label: "精选推荐")
                    ForEach(appModel.categories) { category in
                        categoryCapsule(id: category.id, label: category.name)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                Button {
                    appModel.showSiteSwitcherSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(appModel.activeSite?.name ?? "切换片源")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(TvPillButtonStyle())

                Button {
                    appModel.openLanQrModal()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 16, weight: .semibold))
                        Text("扫码快传")
                    }
                }
                .buttonStyle(TvPillButtonStyle())
            }
        }
    }

    private func categoryCapsule(id: String, label: String) -> some View {
        let isSelected = appModel.selectedCategoryId == id
        return Button {
            Task { await appModel.selectCategory(id) }
        } label: {
            Text(label)
        }
        .buttonStyle(TvPillButtonStyle(active: isSelected))
    }

    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("继续观看")
                .font(TvFont.sectionTitle)
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(appModel.watchHistory.prefix(12), id: \.key) { item in
                        Button {
                            lastOpenedFocus = .continueWatching(item.key)
                            appModel.openWatchHistoryItem(item)
                        } label: {
                            ContinueWatchingCard(
                                item: item,
                                sourceLabel: appModel.originSourceDisplayName(for: item.site)
                            )
                        }
                        .tvCardButtonStyle()
                        .focused($focusedCard, equals: .continueWatching(item.key))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
    }

    private var posterGridWall: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !appModel.watchHistory.isEmpty {
                Text("精选片库")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)
            }

            LazyVGrid(columns: posterColumns, spacing: 32) {
                ForEach(appModel.discoverVideos) { video in
                    Button {
                        if let site = appModel.activeSite {
                            lastOpenedFocus = .poster(video.id)
                            appModel.openDetail(site: site, video: video)
                        }
                    } label: {
                        PosterCardCell(
                            video: video,
                            headers: appModel.activeSite?.headers ?? [:]
                        )
                    }
                    .tvCardButtonStyle()
                    .focused($focusedCard, equals: .poster(video.id))
                    .task {
                        await appModel.loadMoreDiscoverIfNeeded(currentVideo: video)
                    }
                }
            }

            if appModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 24)
                    Spacer()
                }
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    @Environment(\.tvCardFocused) private var isFocused
    let item: WatchHistoryItem
    let sourceLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                RemotePosterView(url: item.poster, title: item.title, cornerRadius: 16)
                    .frame(width: 268, height: 150)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.60))
                        .frame(width: 268, height: 5)
                    Rectangle()
                        .fill(TvTheme.accent)
                        .frame(width: 268 * item.progressFraction, height: 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.white : TvTheme.glassStroke,
                        lineWidth: isFocused ? 2.5 : 1.1
                    )
            )
            .shadow(
                color: isFocused ? Color.black.opacity(0.55) : Color.black.opacity(0.25),
                radius: isFocused ? 18 : 8,
                y: isFocused ? 8 : 4
            )

            Text(item.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 268, alignment: .leading)

            Text(
                item.episode.isEmpty
                    ? "\(sourceLabel) · 继续播放"
                    : "\(sourceLabel) · \(item.episode) · \(Int(item.progressFraction * 100))%"
            )
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(TvTheme.secondaryText)
                .lineLimit(1)
                .frame(width: 268, alignment: .leading)
        }
    }
}

public struct PosterCardCell: View {
    @Environment(\.tvCardFocused) private var isFocused
    public let video: CmsVideo
    public let headers: [String: String]
    public let sourceBadge: String?

    public init(video: CmsVideo, headers: [String: String] = [:], sourceBadge: String? = nil) {
        self.video = video
        self.headers = headers
        self.sourceBadge = sourceBadge
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
                        .font(TvFont.badge)
                        .foregroundColor(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(TvTheme.gold)
                        .clipShape(Capsule())
                        .padding(10)
                } else if !video.remarks.isEmpty {
                    Text(video.remarks)
                        .font(TvFont.badge)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.72))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.white : TvTheme.glassStroke,
                        lineWidth: isFocused ? 2.5 : 1.1
                    )
            )
            .shadow(
                color: isFocused ? Color.black.opacity(0.58) : Color.black.opacity(0.26),
                radius: isFocused ? 20 : 10,
                y: isFocused ? 10 : 5
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(TvFont.cardTitle)
                    .foregroundColor(isFocused ? .white : Color(white: 0.94))
                    .lineLimit(1)

                if let src = sourceBadge, !src.isEmpty {
                    Text(src)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TvTheme.secondaryText)
                        .lineLimit(1)
                } else {
                    let metaParts = [video.year, video.area].filter { !$0.isEmpty }
                    if !metaParts.isEmpty {
                        Text(metaParts.joined(separator: " · "))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(TvTheme.mutedText)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

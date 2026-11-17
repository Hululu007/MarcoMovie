// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LibraryView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum LibrarySection: String, CaseIterable {
        case history = "观看历史"
        case favorites = "我的收藏"
    }

    @State private var section: LibrarySection = .history
    @State private var showClearConfirmation = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 5)

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 18) {
                ForEach(LibrarySection.allCases, id: \.rawValue) { item in
                    Button {
                        section = item
                    } label: {
                        Text(item.rawValue)
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(section == item ? TvTheme.accent : TvTheme.surface)
                            .clipShape(Capsule())
                    }
                    .tvCardButtonStyle()
                }

                Spacer()

                if (section == .history && !appModel.watchHistory.isEmpty)
                    || (section == .favorites && !appModel.favorites.isEmpty)
                {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清空\(section.rawValue)", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView {
                if section == .history {
                    historyGrid
                } else {
                    favoritesGrid
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .confirmationDialog(
            "确认清空全部\(section.rawValue)？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清空", role: .destructive) {
                if section == .history {
                    appModel.clearAllHistory()
                } else {
                    appModel.clearAllFavorites()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var historyGrid: some View {
        if appModel.watchHistory.isEmpty {
            emptyPlaceholder(icon: "clock.arrow.circlepath", text: "暂无观看记录")
        } else {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(appModel.watchHistory) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let site = appModel.config.sites.first(where: { $0.key == item.site }) ?? appModel.activeSite {
                                let stub = CmsVideo(id: item.id, title: item.title, poster: item.poster, remarks: item.episode)
                                appModel.selectedDetailContext = (site, stub)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RemotePosterView(url: item.poster, title: item.title)
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text(item.episode.isEmpty ? "观看进度 \(Int(item.progressFraction * 100))%" : "\(item.episode) · \(Int(item.progressFraction * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(TvTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .tvCardButtonStyle()

                        Button(role: .destructive) {
                            appModel.removeHistoryItem(item)
                        } label: {
                            Label("移除", systemImage: "xmark.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(TvTheme.mutedText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesGrid: some View {
        if appModel.favorites.isEmpty {
            emptyPlaceholder(icon: "heart.slash", text: "暂无收藏影片")
        } else {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(appModel.favorites) { fav in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let site = appModel.config.sites.first(where: { $0.key == fav.site }) ?? appModel.activeSite {
                                let stub = CmsVideo(id: fav.id, title: fav.title, poster: fav.poster, remarks: fav.remarks)
                                appModel.selectedDetailContext = (site, stub)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RemotePosterView(url: fav.poster, title: fav.title)
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                Text(fav.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                if !fav.remarks.isEmpty {
                                    Text(fav.remarks)
                                        .font(.caption2)
                                        .foregroundColor(TvTheme.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .tvCardButtonStyle()

                        Button(role: .destructive) {
                            appModel.removeFavoriteItem(fav)
                        } label: {
                            Label("取消收藏", systemImage: "heart.slash")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(TvTheme.mutedText)
                    }
                }
            }
        }
    }

    private func emptyPlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(TvTheme.mutedText)
            Text(text)
                .foregroundColor(TvTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }
}

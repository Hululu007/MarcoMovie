// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LibraryView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum LibrarySection: String, CaseIterable {
        case history = "观看历史"
        case favorites = "我的收藏"
    }

    private enum LibraryFocusTarget: Hashable {
        case history(String)
        case favorite(String)
    }

    @State private var section: LibrarySection = .history
    @State private var showClearConfirmation = false
    @State private var lastOpenedFocus: LibraryFocusTarget?
    @FocusState private var focusedCard: LibraryFocusTarget?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 6)

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                ForEach(LibrarySection.allCases, id: \.rawValue) { item in
                    Button(item.rawValue) {
                        section = item
                    }
                    .buttonStyle(TvPillButtonStyle(active: section == item))
                }

                Spacer()

                if (section == .history && !appModel.watchHistory.isEmpty)
                    || (section == .favorites && !appModel.favorites.isEmpty)
                {
                    Button {
                        showClearConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("清空\(section.rawValue)")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true, destructive: true))
                }
            }

            ScrollView {
                if section == .history {
                    historyGrid
                } else {
                    favoritesGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 56)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onChange(of: appModel.selectedDetailContext == nil) { isClosed in
            guard isClosed else { return }
            restoreLastOpenedCardFocus()
        }
    }

    private func restoreLastOpenedCardFocus() {
        let available: [LibraryFocusTarget] = section == .history
            ? appModel.watchHistory.map { .history($0.key) }
            : appModel.favorites.map { .favorite($0.key) }
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

    @ViewBuilder
    private var historyGrid: some View {
        if appModel.watchHistory.isEmpty {
            emptyPlaceholder(icon: "clock.arrow.circlepath", text: "暂无观看记录")
        } else {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(appModel.watchHistory, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            lastOpenedFocus = .history(item.key)
                            appModel.openWatchHistoryItem(item)
                        } label: {
                            PosterCardCell(
                                video: CmsVideo(
                                    id: item.id,
                                    title: item.title,
                                    poster: item.poster,
                                    remarks: item.episode.isEmpty ? "\(Int(item.progressFraction * 100))%" : "\(item.episode) · \(Int(item.progressFraction * 100))%"
                                ),
                                sourceBadge: appModel.originSourceDisplayName(for: item.site)
                            )
                        }
                        .tvCardButtonStyle()
                        .focused($focusedCard, equals: .history(item.key))

                        Button {
                            appModel.removeHistoryItem(item)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle")
                                Text("移除记录")
                            }
                        }
                        .buttonStyle(TvPillButtonStyle(compact: true))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var favoritesGrid: some View {
        if appModel.favorites.isEmpty {
            emptyPlaceholder(icon: "heart.slash", text: "暂无收藏影片")
        } else {
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(appModel.favorites, id: \.key) { fav in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            lastOpenedFocus = .favorite(fav.key)
                            appModel.openFavoriteItem(fav)
                        } label: {
                            PosterCardCell(
                                video: CmsVideo(
                                    id: fav.id,
                                    title: fav.title,
                                    poster: fav.poster,
                                    remarks: fav.remarks
                                ),
                                sourceBadge: appModel.originSourceDisplayName(for: fav.site)
                            )
                        }
                        .tvCardButtonStyle()
                        .focused($focusedCard, equals: .favorite(fav.key))

                        Button {
                            appModel.removeFavoriteItem(fav)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.slash")
                                Text("取消收藏")
                            }
                        }
                        .buttonStyle(TvPillButtonStyle(compact: true))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func emptyPlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(TvTheme.mutedText)
            Text(text)
                .font(TvFont.body)
                .foregroundColor(TvTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
    }
}

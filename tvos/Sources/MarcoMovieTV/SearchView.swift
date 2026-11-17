// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct SearchView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum KeyPadMode: String, CaseIterable {
        case abc = "ABC / 拼音首字母"
        case digits = "123 数字"
    }

    @State private var keyMode: KeyPadMode = .abc

    private let alphaKeys: [String] = [
        "A", "B", "C", "D", "E", "F",
        "G", "H", "I", "J", "K", "L",
        "M", "N", "O", "P", "Q", "R",
        "S", "T", "U", "V", "W", "X",
        "Y", "Z", " ", "-", "1", "2",
    ]

    private let digitKeys: [String] = [
        "1", "2", "3", "4", "5", "6",
        "7", "8", "9", "0", "S", "E",
    ]

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 36) {
            // Left: Remote-friendly On-Screen Grid Keyboard + System TextField
            VStack(alignment: .leading, spacing: 18) {
                Text("聚合搜索")
                    .font(.title3.bold())
                    .foregroundColor(.white)

                TextField("输入片名、演员或使用遥控器语音听写", text: $appModel.searchQuery)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit {
                        appModel.triggerGlobalSearch()
                    }

                HStack(spacing: 10) {
                    ForEach(KeyPadMode.allCases, id: \.rawValue) { mode in
                        Button {
                            keyMode = mode
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(keyMode == mode ? TvTheme.accent : TvTheme.surface)
                                .clipShape(Capsule())
                        }
                        .tvCardButtonStyle()
                    }
                }

                let activeKeys = keyMode == .abc ? alphaKeys : digitKeys
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(activeKeys, id: \.self) { key in
                        Button {
                            appModel.searchQuery.append(key == " " ? " " : key.lowercased())
                        } label: {
                            Text(key == " " ? "␣" : key)
                                .font(.callout.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(TvTheme.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .tvCardButtonStyle()
                    }
                }

                HStack(spacing: 10) {
                    Button("退格") {
                        if !appModel.searchQuery.isEmpty {
                            appModel.searchQuery.removeLast()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("清空") {
                        appModel.searchQuery = ""
                    }
                    .buttonStyle(.bordered)

                    Button("立即搜索") {
                        appModel.triggerGlobalSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TvTheme.accent)
                }

                let history = appModel.storage.searchHistory()
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近搜索")
                                .font(.caption)
                                .foregroundColor(TvTheme.mutedText)
                            Spacer()
                            Button("清除") {
                                appModel.storage.clearSearchHistory()
                            }
                            .font(.caption2)
                            .buttonStyle(.plain)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(history, id: \.self) { kw in
                                    Button {
                                        appModel.searchQuery = kw
                                        appModel.triggerGlobalSearch()
                                    } label: {
                                        Text(kw)
                                            .font(.caption)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(TvTheme.surface)
                                            .clipShape(Capsule())
                                    }
                                    .tvCardButtonStyle()
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 400)

            // Right: Concurrent Multi-Site Streaming Results + Unsupported Notice
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    let unsupportedCount = appModel.config.unsupportedSites.count
                    if unsupportedCount > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundColor(TvTheme.mutedText)
                            Text("并发检索可用片源 \(appModel.config.publicAvailableSites.count) 个（另有 \(unsupportedCount) 个依赖 Android JAR/原生组件的线路已自动置灰跳过）")
                                .font(.caption)
                                .foregroundColor(TvTheme.mutedText)
                        }
                        .padding(12)
                        .background(TvTheme.surface.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if appModel.isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在多站并发搜索「\(appModel.searchQuery)」… 已命中 \(appModel.searchBatches.count) 个片源")
                                .font(.callout)
                                .foregroundColor(TvTheme.secondaryText)
                        }
                    }

                    if !appModel.isSearching && appModel.searchBatches.isEmpty && !appModel.searchQuery.isEmpty {
                        Text("未找到匹配的影视内容，可尝试缩短关键词")
                            .foregroundColor(TvTheme.secondaryText)
                            .padding(.top, 40)
                    }

                    ForEach(appModel.searchBatches) { batch in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(batch.site.name)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("\(batch.videos.count) 部")
                                    .font(.caption)
                                    .foregroundColor(TvTheme.secondaryText)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 22) {
                                    ForEach(batch.videos) { video in
                                        Button {
                                            appModel.selectedDetailContext = (batch.site, video)
                                        } label: {
                                            PosterCardCell(video: video, headers: batch.site.headers)
                                                .frame(width: 190)
                                        }
                                        .tvCardButtonStyle()
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
    }
}

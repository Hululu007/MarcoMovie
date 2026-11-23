// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct SearchView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum KeyPadMode: String, CaseIterable {
        case abc = "ABC 拼音"
        case digits = "123 数字"
    }

    @State private var keyMode: KeyPadMode = .abc
    @State private var selectedSourceKey: String = "__all__"
    @State private var lastOpenedResultId: String?
    @FocusState private var focusedResultId: String?

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

    private let resultColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 24),
        count: 5
    )

    public init() {}

    private struct MergedSearchItem: Identifiable {
        let id: String
        let site: CmsSite
        let video: CmsVideo
    }

    private var filteredItems: [MergedSearchItem] {
        var out: [MergedSearchItem] = []
        for batch in appModel.searchBatches {
            if selectedSourceKey != "__all__" && batch.site.key != selectedSourceKey {
                continue
            }
            for v in batch.videos {
                out.append(
                    MergedSearchItem(
                        id: "\(batch.site.key)::\(v.id)",
                        site: batch.site,
                        video: v
                    )
                )
            }
        }
        return out
    }

    private var totalMatchedCount: Int {
        appModel.searchBatches.reduce(0) { $0 + $1.videos.count }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 36) {
            // Left: Remote-friendly On-Screen Grid Keyboard + Large Search Box
            VStack(alignment: .leading, spacing: 18) {
                Text("多站聚合搜索")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)

                // Prominent Large-Font Search Input Box (28pt bold, zero nested UITextField box)
                TvGlassInputField(
                    title: "多站聚合搜索",
                    placeholder: "输入片名、首字母或点击语音",
                    text: $appModel.searchQuery,
                    systemImage: "magnifyingglass",
                    large: true,
                    showVoiceBadge: true,
                    onSubmit: {
                        selectedSourceKey = "__all__"
                        appModel.triggerGlobalSearch()
                    }
                )

                HStack(spacing: 12) {
                    ForEach(KeyPadMode.allCases, id: \.rawValue) { mode in
                        Button(mode.rawValue) {
                            keyMode = mode
                        }
                        .buttonStyle(TvPillButtonStyle(active: keyMode == mode, compact: true))
                    }
                    Spacer()
                }

                let activeKeys = keyMode == .abc ? alphaKeys : digitKeys
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6), spacing: 9) {
                    ForEach(activeKeys, id: \.self) { key in
                        Button {
                            appModel.searchQuery.append(key == " " ? " " : key.lowercased())
                        } label: {
                            Text(key == " " ? "空格" : key)
                                .font(.system(size: key == " " ? 15 : 20, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(TvTileButtonStyle(cornerRadius: 12))
                    }
                }
                .padding(4)

                HStack(spacing: 10) {
                    Button {
                        if !appModel.searchQuery.isEmpty {
                            appModel.searchQuery.removeLast()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "delete.left")
                            Text("退格")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true, fullWidth: true))

                    Button("清空") {
                        appModel.searchQuery = ""
                    }
                    .buttonStyle(TvPillButtonStyle(compact: true, fullWidth: true))

                    Button {
                        selectedSourceKey = "__all__"
                        appModel.triggerGlobalSearch()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("搜索")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(prominent: true, compact: true, fullWidth: true))
                }

                let history = appModel.storage.searchHistory()
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("最近搜索")
                                .font(TvFont.caption)
                                .foregroundColor(TvTheme.secondaryText)
                            Spacer()
                            Button("清除") {
                                appModel.storage.clearSearchHistory()
                            }
                            .buttonStyle(TvPillButtonStyle(compact: true))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(history, id: \.self) { kw in
                                    Button(kw) {
                                        appModel.searchQuery = kw
                                        selectedSourceKey = "__all__"
                                        appModel.triggerGlobalSearch()
                                    }
                                    .buttonStyle(TvPillButtonStyle(compact: true))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(26)
            .frame(width: 456)
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(TvTheme.glassStroke, lineWidth: 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Right: Full-Width 5-Column Multi-Source Poster Wall (Zero Right-Side Dead Space)
            VStack(alignment: .leading, spacing: 20) {
                if !appModel.searchBatches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button("全部结果 (\(totalMatchedCount))") {
                                selectedSourceKey = "__all__"
                            }
                            .buttonStyle(TvPillButtonStyle(active: selectedSourceKey == "__all__"))

                            ForEach(appModel.searchBatches) { batch in
                                Button("\(batch.site.name) (\(batch.videos.count))") {
                                    selectedSourceKey = batch.site.key
                                }
                                .buttonStyle(TvPillButtonStyle(active: selectedSourceKey == batch.site.key))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if appModel.isSearching {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("正在多站并发搜索「\(appModel.searchQuery)」… 已命中 \(appModel.searchBatches.count) 个片源")
                                    .font(TvFont.body)
                                    .foregroundColor(TvTheme.secondaryText)
                            }
                            .padding(.top, 8)
                        } else if appModel.searchBatches.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 52))
                                    .foregroundColor(TvTheme.mutedText)
                                Text(appModel.searchQuery.isEmpty ? "在左侧输入关键词或拼音首字母，即可跨全部可用片源并发检索" : "未找到匹配的影视内容，可尝试缩短关键词")
                                    .font(TvFont.body)
                                    .foregroundColor(TvTheme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 140)
                        }

                        if !filteredItems.isEmpty {
                            LazyVGrid(columns: resultColumns, spacing: 28) {
                                ForEach(filteredItems) { item in
                                    Button {
                                        lastOpenedResultId = item.id
                                        appModel.openDetail(site: item.site, video: item.video)
                                    } label: {
                                        PosterCardCell(
                                            video: item.video,
                                            headers: item.site.headers,
                                            sourceBadge: item.site.name
                                        )
                                    }
                                    .tvCardButtonStyle()
                                    .focused($focusedResultId, equals: item.id)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 36)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 56)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: appModel.selectedDetailContext == nil) { isClosed in
            guard isClosed else { return }
            guard let targetId = FocusRestorationPlanner.resolvePosterCardReturn(
                lastOpenedKey: lastOpenedResultId,
                availableKeys: filteredItems.map(\.id)
            ) else {
                return
            }
            focusedResultId = targetId
            DispatchQueue.main.async {
                self.focusedResultId = targetId
            }
        }
    }
}

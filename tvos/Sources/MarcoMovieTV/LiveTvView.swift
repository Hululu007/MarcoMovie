// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LiveTvView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    private var supportedLives: [LiveSource] {
        appModel.config.publicSupportedLives
    }

    private var activeGroup: LiveGroup? {
        guard appModel.liveGroups.indices.contains(appModel.selectedLiveGroupIndex) else { return nil }
        return appModel.liveGroups[appModel.selectedLiveGroupIndex]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Text("电视直播")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)

                if supportedLives.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(supportedLives.enumerated()), id: \.offset) { idx, src in
                                Button(src.name) {
                                    Task { await appModel.loadLiveCatalog(sourceIndex: idx) }
                                }
                                .buttonStyle(TvPillButtonStyle(active: appModel.selectedLiveSourceIndex == idx, compact: true))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                }

                Spacer()

                Text("全屏播放时按遥控器上 / 下方向键即可快速换台")
                    .font(TvFont.caption)
                    .foregroundColor(TvTheme.mutedText)
            }

            if supportedLives.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "tv.slash")
                        .font(.system(size: 48))
                        .foregroundColor(TvTheme.mutedText)
                    Text("当前订阅中未包含可用的 M3U / TXT 直播源")
                        .font(TvFont.body)
                        .foregroundColor(TvTheme.secondaryText)
                    Button("扫码推送 M3U 直播源") {
                        appModel.openLanQrModal()
                    }
                    .buttonStyle(TvPillButtonStyle(prominent: true))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.isLoadingLive {
                VStack {
                    Spacer()
                    ProgressView("正在解析直播频道列表…")
                        .font(TvFont.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = appModel.liveError {
                VStack(spacing: 14) {
                    Spacer()
                    Text("直播列表加载失败：\(err)")
                        .font(TvFont.body)
                        .foregroundColor(.orange)
                    Button("重新加载") {
                        Task { await appModel.loadLiveCatalog(sourceIndex: appModel.selectedLiveSourceIndex) }
                    }
                    .buttonStyle(TvPillButtonStyle(prominent: true))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    // Left group list
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(appModel.liveGroups.enumerated()), id: \.offset) { idx, group in
                                let selected = appModel.selectedLiveGroupIndex == idx
                                Button {
                                    appModel.selectedLiveGroupIndex = idx
                                } label: {
                                    HStack {
                                        Text(group.name)
                                            .font(TvFont.button)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.channels.count)")
                                            .font(TvFont.caption)
                                            .opacity(0.75)
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(TvTileButtonStyle(active: selected, cornerRadius: 14))
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: 270)

                    // Right channel list
                    ScrollView {
                        if let grp = activeGroup {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                                spacing: 16
                            ) {
                                ForEach(grp.channels) { channel in
                                    Button {
                                        appModel.startLivePlayback(channel: channel)
                                    } label: {
                                        HStack(spacing: 14) {
                                            if !channel.logo.isEmpty {
                                                RemotePosterView(url: channel.logo, title: channel.name, cornerRadius: 10)
                                                    .frame(width: 50, height: 50)
                                            } else {
                                                ZStack {
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .fill(TvTheme.accent.opacity(0.20))
                                                        .frame(width: 50, height: 50)
                                                    Image(systemName: "play.tv.fill")
                                                        .font(.system(size: 18, weight: .semibold))
                                                        .foregroundColor(TvTheme.accent)
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(channel.name)
                                                    .font(TvFont.cardTitle)
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                Text("可用线路 \(channel.episodes.count) 条")
                                                    .font(TvFont.caption)
                                                    .foregroundColor(TvTheme.secondaryText)
                                            }
                                            Spacer()
                                        }
                                        .padding(14)
                                    }
                                    .buttonStyle(TvTileButtonStyle(cornerRadius: 16, preserveColors: true))
                                }
                            }
                            .padding(4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if appModel.liveGroups.isEmpty && !supportedLives.isEmpty {
                await appModel.loadLiveCatalog(sourceIndex: appModel.selectedLiveSourceIndex)
            }
        }
    }
}

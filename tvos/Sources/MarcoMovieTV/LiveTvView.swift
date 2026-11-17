// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LiveTvView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    private var supportedLives: [LiveSource] {
        appModel.config.supportedLives
    }

    private var activeGroup: LiveGroup? {
        guard appModel.liveGroups.indices.contains(appModel.selectedLiveGroupIndex) else { return nil }
        return appModel.liveGroups[appModel.selectedLiveGroupIndex]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Text("电视直播")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                if supportedLives.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(supportedLives.enumerated()), id: \.offset) { idx, src in
                                Button {
                                    Task { await appModel.loadLiveCatalog(sourceIndex: idx) }
                                } label: {
                                    Text(src.name)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(appModel.selectedLiveSourceIndex == idx ? TvTheme.accent : TvTheme.surface)
                                        .clipShape(Capsule())
                                }
                                .tvCardButtonStyle()
                            }
                        }
                    }
                }

                Spacer()

                Text("全屏播放时按遥控器上 / 下方向键即可快速换台")
                    .font(.caption)
                    .foregroundColor(TvTheme.mutedText)
            }

            if supportedLives.isEmpty {
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "tv.slash")
                        .font(.system(size: 54))
                        .foregroundColor(TvTheme.mutedText)
                    Text("当前订阅中未包含可用的 M3U / TXT 直播源")
                        .foregroundColor(TvTheme.secondaryText)
                    Button("扫码推送 M3U 直播源") {
                        appModel.openLanQrModal()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if appModel.isLoadingLive {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("正在解析直播频道列表…")
                    Spacer()
                }
                Spacer()
            } else if let err = appModel.liveError {
                VStack(spacing: 14) {
                    Text("直播列表加载失败：\(err)")
                        .foregroundColor(.orange)
                    Button("重新加载") {
                        Task { await appModel.loadLiveCatalog(sourceIndex: appModel.selectedLiveSourceIndex) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(alignment: .top, spacing: 32) {
                    // Left group list
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(appModel.liveGroups.enumerated()), id: \.offset) { idx, group in
                                let selected = appModel.selectedLiveGroupIndex == idx
                                Button {
                                    appModel.selectedLiveGroupIndex = idx
                                } label: {
                                    HStack {
                                        Text(group.name)
                                            .font(.callout.weight(selected ? .bold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(group.channels.count)")
                                            .font(.caption2)
                                            .foregroundColor(TvTheme.secondaryText)
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    .background(selected ? TvTheme.accent : TvTheme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .tvCardButtonStyle()
                            }
                        }
                    }
                    .frame(width: 300)

                    // Right channel list
                    ScrollView {
                        if let grp = activeGroup {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 280), spacing: 18)],
                                spacing: 18
                            ) {
                                ForEach(grp.channels) { channel in
                                    Button {
                                        appModel.startLivePlayback(channel: channel)
                                    } label: {
                                        HStack(spacing: 14) {
                                            if !channel.logo.isEmpty {
                                                RemotePosterView(url: channel.logo, title: channel.name, cornerRadius: 10)
                                                    .frame(width: 56, height: 56)
                                            } else {
                                                Image(systemName: "play.tv.fill")
                                                    .font(.title3)
                                                    .foregroundColor(TvTheme.accent)
                                                    .frame(width: 56, height: 56)
                                                    .background(TvTheme.surface)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(channel.name)
                                                    .font(.callout.weight(.semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                Text("线路数：\(channel.episodes.count)")
                                                    .font(.caption2)
                                                    .foregroundColor(TvTheme.secondaryText)
                                            }
                                            Spacer()
                                        }
                                        .padding(14)
                                        .background(TvTheme.elevatedSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                    .tvCardButtonStyle()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .task {
            if appModel.liveGroups.isEmpty && !supportedLives.isEmpty {
                await appModel.loadLiveCatalog(sourceIndex: appModel.selectedLiveSourceIndex)
            }
        }
    }
}

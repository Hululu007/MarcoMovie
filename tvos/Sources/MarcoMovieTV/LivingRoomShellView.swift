// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LivingRoomShellView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if !appModel.hasConfiguredSources && appModel.selectedTab == .discover {
                    WelcomeEmptyStateView()
                } else {
                    TabView(selection: $appModel.selectedTab) {
                        DiscoverView()
                            .tabItem { Label("发现", systemImage: "sparkles.tv") }
                            .tag(LivingRoomTab.discover)

                        LiveTvView()
                            .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
                            .tag(LivingRoomTab.live)

                        SearchView()
                            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                            .tag(LivingRoomTab.search)

                        LibraryView()
                            .tabItem { Label("片库", systemImage: "books.vertical") }
                            .tag(LivingRoomTab.library)

                        SettingsView()
                            .tabItem { Label("设置", systemImage: "gearshape") }
                            .tag(LivingRoomTab.settings)
                    }
                }

                if let banner = appModel.statusBannerMessage {
                    Text(banner)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 36)
                        .task(id: banner) {
                            try? await Task.sleep(nanoseconds: 3_500_000_000)
                            if appModel.statusBannerMessage == banner {
                                appModel.statusBannerMessage = nil
                            }
                        }
                }
            }
            .sheet(isPresented: $appModel.showSiteSwitcherSheet) {
                SiteDepotSwitcherSheet()
                    .environmentObject(appModel)
            }
            .sheet(isPresented: $appModel.showLanQrModal) {
                LanQrPushModalView()
                    .environmentObject(appModel)
            }
            .sheet(
                isPresented: Binding(
                    get: { appModel.selectedDetailContext != nil },
                    set: { if !$0 { appModel.selectedDetailContext = nil } }
                )
            ) {
                if let ctx = appModel.selectedDetailContext {
                    DetailView(site: ctx.site, summaryVideo: ctx.video)
                        .environmentObject(appModel)
                }
            }
            #if os(tvOS)
            .fullScreenCover(item: $appModel.activePlayback) { session in
                TvPlayerView(session: session)
                    .environmentObject(appModel)
                    .ignoresSafeArea()
            }
            #else
            .sheet(item: $appModel.activePlayback) { session in
                TvPlayerView(session: session)
                    .environmentObject(appModel)
                    .frame(minWidth: 960, minHeight: 540)
            }
            #endif
        }
    }
}

public struct WelcomeEmptyStateView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "appletv.fill")
                .font(.system(size: 72))
                .foregroundColor(TvTheme.accent)

            Text("Marco Movie · Apple TV")
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text("本软件仅提供通用媒体目录解析与本地播放能力，不内置、不提供、不托管任何影视或直播内容。")
                .font(.callout)
                .foregroundColor(TvTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 820)

            HStack(spacing: 24) {
                Button {
                    appModel.openLanQrModal()
                } label: {
                    Label("手机扫码推送配置", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(TvTheme.accent)

                Button {
                    appModel.selectedTab = .settings
                } label: {
                    Label("打开设置与云同步", systemImage: "icloud.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(48)
    }
}

public struct SiteDepotSwitcherSheet: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("切换片源与多仓线路")
                        .font(.title2.bold())
                    Spacer()
                    Text("可用 \(appModel.config.availableSites.count) / 共 \(appModel.config.sites.count)")
                        .font(.callout)
                        .foregroundColor(TvTheme.secondaryText)
                    Button("关闭") { dismiss() }
                }

                if !appModel.config.depots.isEmpty {
                    Text("多仓仓库列表")
                        .font(.headline)
                        .foregroundColor(TvTheme.secondaryText)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 18) {
                        ForEach(appModel.config.depots) { depot in
                            Button {
                                dismiss()
                                Task { await appModel.switchDepot(depot) }
                            } label: {
                                HStack {
                                    Image(systemName: "shippingbox.fill")
                                        .foregroundColor(TvTheme.gold)
                                    Text(depot.name)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(16)
                                .background(TvTheme.elevatedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .tvCardButtonStyle()
                        }
                    }
                }

                Text("已启用片源")
                    .font(.headline)
                    .foregroundColor(TvTheme.secondaryText)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 18) {
                    ForEach(appModel.config.publicAvailableSites) { site in
                        Button {
                            appModel.selectSite(site)
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(appModel.activeSite?.key == site.key ? TvTheme.accent : Color.green)
                                    .frame(width: 10, height: 10)
                                Text(site.name)
                                    .lineLimit(1)
                                Spacer()
                                if site.hasQuickJsAdapter {
                                    Text("JS")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(TvTheme.accent.opacity(0.25))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(16)
                            .background(
                                appModel.activeSite?.key == site.key
                                    ? TvTheme.accent.opacity(0.28)
                                    : TvTheme.elevatedSurface
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .tvCardButtonStyle()
                    }
                }
            }
            .padding(40)
        }
        .background(TvTheme.background)
    }
}

public struct LanQrPushModalView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Text("手机扫码推送配置或备份")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("请确保手机与 Apple TV 连接同一局域网 Wi-Fi，使用手机相机或浏览器扫描二维码即可免遥控器输入推送订阅链接、JSON 配置或 marco-movie-backup.json 备份文件。")
                .font(.callout)
                .foregroundColor(TvTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            QrCodeImageView(payload: appModel.lanQrUrl, size: 280)

            if !appModel.lanQrUrl.isEmpty {
                Text(appModel.lanQrUrl)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(TvTheme.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 20) {
                Button("刷新二维码") {
                    Task { await appModel.startOrRefreshLanServer() }
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    appModel.closeLanQrModal()
                }
                .buttonStyle(.borderedProminent)
                .tint(TvTheme.accent)
            }
        }
        .padding(48)
        .background(TvTheme.background)
        .tvExitHandler {
            appModel.closeLanQrModal()
        }
    }
}

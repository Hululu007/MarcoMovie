// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct LivingRoomShellView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            if !appModel.hasConfiguredSources && appModel.selectedTab == .discover {
                WelcomeEmptyStateView()
                    .tvAmbientPageBackground(appModel)
            } else {
                TabView(selection: $appModel.selectedTab) {
                    DiscoverView()
                        .tvAmbientPageBackground(appModel)
                        .tabItem { Label("发现", systemImage: "sparkles.tv") }
                        .tag(LivingRoomTab.discover)

                    LiveTvView()
                        .tvAmbientPageBackground(appModel)
                        .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
                        .tag(LivingRoomTab.live)

                    SearchView()
                        .tvAmbientPageBackground(appModel)
                        .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                        .tag(LivingRoomTab.search)

                    LibraryView()
                        .tvAmbientPageBackground(appModel)
                        .tabItem { Label("片库", systemImage: "books.vertical") }
                        .tag(LivingRoomTab.library)

                    SettingsView()
                        .tvAmbientPageBackground(appModel)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(LivingRoomTab.settings)
                }
            }

            if let banner = appModel.statusBannerMessage {
                Text(banner)
                    .font(TvFont.button)
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(TvTheme.elevatedSurface.opacity(0.95))
                    .overlay(Capsule().strokeBorder(TvTheme.glassStroke, lineWidth: 1))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .padding(.bottom, 32)
                    .task(id: banner) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if appModel.statusBannerMessage == banner {
                            appModel.statusBannerMessage = nil
                        }
                    }
            }
        }
        .overlay {
            if appModel.hasConfiguredSources || appModel.selectedTab != .discover {
                MarcoBrandLogo(iconSize: 44, fontSize: 26)
                    .padding(.leading, 56)
                    .padding(.top, 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $appModel.showSiteSwitcherSheet) {
            SiteDepotSwitcherSheet()
                .environmentObject(appModel)
        }
        .fullScreenCover(isPresented: $appModel.showLanQrModal) {
            LanQrPushModalView()
                .environmentObject(appModel)
        }
        .fullScreenCover(isPresented: $appModel.showNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        .fullScreenCover(item: $appModel.selectedDetailContext) { ctx in
            DetailView(site: ctx.site, summaryVideo: ctx.video)
                .environmentObject(appModel)
        }
        .fullScreenCover(item: $appModel.activePlayback) { session in
            TvPlayerView(session: session)
                .environmentObject(appModel)
                .ignoresSafeArea()
        }
        #else
        .sheet(isPresented: $appModel.showSiteSwitcherSheet) {
            SiteDepotSwitcherSheet()
                .environmentObject(appModel)
        }
        .sheet(isPresented: $appModel.showLanQrModal) {
            LanQrPushModalView()
                .environmentObject(appModel)
        }
        .sheet(isPresented: $appModel.showNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        .sheet(item: $appModel.selectedDetailContext) { ctx in
            DetailView(site: ctx.site, summaryVideo: ctx.video)
                .environmentObject(appModel)
        }
        .sheet(item: $appModel.activePlayback) { session in
            TvPlayerView(session: session)
                .environmentObject(appModel)
                .frame(minWidth: 960, minHeight: 540)
        }
        #endif
    }
}

public struct WelcomeEmptyStateView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(spacing: 22) {
            Spacer()

            MarcoBrandLogo(iconSize: 84, fontSize: 44, stacked: true)

            Text("本软件仅提供通用媒体目录解析与本地播放能力，不内置、不提供、不托管任何影视或直播内容。")
                .font(TvFont.body)
                .foregroundColor(TvTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)

            HStack(spacing: 18) {
                Button {
                    appModel.openLanQrModal()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("手机扫码推送配置")
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))

                Button {
                    appModel.selectedTab = .settings
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.down")
                        Text("打开设置与云同步")
                    }
                }
                .buttonStyle(TvPillButtonStyle())
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public struct SiteDepotSwitcherSheet: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                MarcoBrandLogo(iconSize: 40, fontSize: 23)
                Rectangle()
                    .fill(TvTheme.glassStroke)
                    .frame(width: 1.5, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("切换片源与多仓线路")
                        .font(TvFont.pageTitle)
                        .foregroundColor(.white)
                    Text("可用 \(appModel.config.publicAvailableSites.count) / 共 \(appModel.config.sites.filter { !$0.isEffectivelyPrivate }.count) 个片源")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(TvPillButtonStyle())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !appModel.config.publicDepots.isEmpty {
                        Text("多仓仓库列表")
                            .font(TvFont.sectionTitle)
                            .foregroundColor(.white)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                            ForEach(appModel.config.publicDepots) { depot in
                                Button {
                                    dismiss()
                                    Task { await appModel.switchDepot(depot) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "shippingbox.fill")
                                            .foregroundColor(TvTheme.gold)
                                        Text(depot.name)
                                            .font(TvFont.cardTitle)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(TvTileButtonStyle(preserveColors: true))
                            }
                        }
                    }

                    Text("已启用片源")
                        .font(TvFont.sectionTitle)
                        .foregroundColor(.white)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(appModel.config.publicAvailableSites) { site in
                            let isActive = appModel.activeSite?.key == site.key
                            Button {
                                appModel.selectSite(site)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(isActive ? TvTheme.accent : Color.green)
                                        .frame(width: 9, height: 9)
                                    Text(site.name)
                                        .font(TvFont.cardTitle)
                                        .lineLimit(1)
                                    Spacer()
                                    if site.hasQuickJsAdapter {
                                        Text("JS")
                                            .font(TvFont.badge)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(TvTheme.accent.opacity(0.28))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(TvTileButtonStyle(active: isActive, preserveColors: true))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            TvAmbientSoftGlowBackground(
                themeId: appModel.preferences.ambientTheme,
                intensity: appModel.preferences.ambientIntensity,
                posterUrl: appModel.backdropPosterUrl,
                posterSync: appModel.preferences.ambientPosterSync
            )
        )
        .tvExitHandler { dismiss() }
    }
}

public struct LanQrPushModalView: View {
    @EnvironmentObject private var appModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(spacing: 22) {
            Spacer()

            MarcoBrandLogo(iconSize: 48, fontSize: 28)

            Text("手机扫码推送配置或备份")
                .font(TvFont.pageTitle)
                .foregroundColor(.white)

            Text("请确保手机与 Apple TV 连接同一局域网 Wi-Fi，使用手机相机或浏览器扫描下方二维码，即可免输入推送订阅链接、JSON 配置或备份文件。")
                .font(TvFont.body)
                .foregroundColor(TvTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)

            QrCodeImageView(
                payload: appModel.lanBindQrPayload.isEmpty ? appModel.lanQrUrl : appModel.lanBindQrPayload,
                size: 230
            )

            if !appModel.lanQrUrl.isEmpty {
                Text(appModel.lanQrUrl)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(TvTheme.accent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(TvTheme.surface)
                    .overlay(Capsule().strokeBorder(TvTheme.glassStroke, lineWidth: 1))
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                Button {
                    Task { await appModel.startOrRefreshLanServer() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新二维码")
                    }
                }
                .buttonStyle(TvPillButtonStyle())

                Button("完成") {
                    appModel.closeLanQrModal()
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
            }
            .padding(.top, 6)

            Spacer()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            TvAmbientSoftGlowBackground(
                themeId: appModel.preferences.ambientTheme,
                intensity: appModel.preferences.ambientIntensity,
                posterUrl: appModel.backdropPosterUrl,
                posterSync: appModel.preferences.ambientPosterSync
            )
        )
        .tvExitHandler {
            appModel.closeLanQrModal()
        }
    }
}

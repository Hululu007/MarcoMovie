// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MarcoTVCore
import SwiftUI

@main
public struct MarcoMovieTVApp: App {
    @StateObject private var appModel = AppViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            LivingRoomShellView()
                .environmentObject(appModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    TvAmbientSoftGlowBackground(
                        themeId: appModel.preferences.ambientTheme,
                        intensity: appModel.preferences.ambientIntensity,
                        posterUrl: appModel.backdropPosterUrl,
                        posterSync: appModel.preferences.ambientPosterSync
                    )
                )
                .preferredColorScheme(.dark)
                #if targetEnvironment(simulator)
                .task {
                    await applySimulatorSceneIfRequested(appModel: appModel)
                }
                #endif
        }
    }

    #if targetEnvironment(simulator)
    @MainActor
    private func applySimulatorSceneIfRequested(appModel: AppViewModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let scene = env["MARCO_SIM_SCENE"], !scene.isEmpty else {
            return
        }
        if let theme = env["MARCO_SIM_THEME"], !theme.isEmpty {
            appModel.updatePlaybackPreferences {
                $0.ambientTheme = theme
                $0.ambientIntensity = env["MARCO_SIM_INTENSITY"] ?? "standard"
            }
        }
        if let demoUrl = env["MARCO_SIM_DEMO_URL"], !demoUrl.isEmpty {
            if appModel.subscriptions.isEmpty {
                try? await appModel.importSubscriptionFromUrl(demoUrl, name: "家庭影院主源")
            }
            if let site = appModel.activeSite {
                if appModel.discoverVideos.isEmpty {
                    await appModel.loadHomeForActiveSite()
                }
                if let firstVideo = appModel.discoverVideos.first {
                    appModel.storage.upsertWatchHistory(
                        WatchHistoryItem(
                            site: site.key,
                            id: firstVideo.id,
                            title: firstVideo.title,
                            poster: firstVideo.poster,
                            line: "我的夸父4K",
                            episode: "第02集",
                            index: 1,
                            position: 1_122_000,
                            duration: 2_895_000,
                            updated: Int64(Date().timeIntervalSince1970 * 1000)
                        )
                    )
                    appModel.reloadLocalState()
                }
            }
            if !appModel.config.supportedLives.isEmpty && appModel.liveGroups.isEmpty {
                await appModel.loadLiveCatalog(sourceIndex: 0)
            }
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        switch scene {
        case "discover", "discover_twilight":
            appModel.selectedTab = .discover
        case "detail", "episodes":
            appModel.selectedTab = .discover
            if let site = appModel.activeSite, let first = appModel.discoverVideos.first {
                appModel.selectedDetailContext = (site: site, video: first)
            }
        case "netdisk":
            appModel.selectedTab = .discover
            appModel.showNetdiskSheet = true
        case "live":
            appModel.selectedTab = .live
            try? await Task.sleep(nanoseconds: 450_000_000)
            appModel.selectedTab = .live
        case "search":
            appModel.selectedTab = .search
            try? await Task.sleep(nanoseconds: 350_000_000)
            appModel.selectedTab = .search
            appModel.searchQuery = "远山"
            appModel.triggerGlobalSearch()
        case "library":
            appModel.selectedTab = .library
        case "settings":
            appModel.selectedTab = .settings
            try? await Task.sleep(nanoseconds: 450_000_000)
            appModel.selectedTab = .settings
        default:
            break
        }
    }
    #endif
}

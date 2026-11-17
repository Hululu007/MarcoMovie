// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

@main
public struct MarcoMovieTVApp: App {
    @StateObject private var appModel = AppViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ZStack {
                TvTheme.background.ignoresSafeArea()

                if !appModel.backdropPosterUrl.isEmpty {
                    RemotePosterView(
                        url: appModel.backdropPosterUrl,
                        title: "",
                        cornerRadius: 0
                    )
                    .opacity(0.22)
                    .blur(radius: 68)
                    .ignoresSafeArea()
                }

                LinearGradient(
                    colors: [
                        TvTheme.background.opacity(0.60),
                        TvTheme.background.opacity(0.94),
                        TvTheme.background,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                LivingRoomShellView()
                    .environmentObject(appModel)
            }
            .preferredColorScheme(.dark)
        }
    }
}

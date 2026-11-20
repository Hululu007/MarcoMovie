// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

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
        }
    }
}

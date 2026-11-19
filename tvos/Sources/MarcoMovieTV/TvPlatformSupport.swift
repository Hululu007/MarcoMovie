// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CoreImage
import Foundation
import MarcoTVCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct TvAmbientPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let baseStart: Color
    public let baseMid: Color
    public let baseEnd: Color
    public let orbPrimary: Color
    public let orbSecondary: Color
    public let orbWarm: Color
    public let accent: Color

    public static let allPresets: [TvAmbientPreset] = [
        TvAmbientPreset(
            id: "aurora",
            name: "极光青翠",
            subtitle: "翡翠湖光与晴空柔雾",
            baseStart: Color(red: 0.06, green: 0.17, blue: 0.24),
            baseMid: Color(red: 0.07, green: 0.12, blue: 0.22),
            baseEnd: Color(red: 0.10, green: 0.10, blue: 0.23),
            orbPrimary: Color(red: 0.08, green: 0.78, blue: 0.68),
            orbSecondary: Color(red: 0.22, green: 0.58, blue: 0.98),
            orbWarm: Color(red: 0.38, green: 0.34, blue: 0.88),
            accent: Color(red: 0.18, green: 0.58, blue: 0.96)
        ),
        TvAmbientPreset(
            id: "twilight",
            name: "暮色流光",
            subtitle: "鸢尾紫霞与玫瑰晚风",
            baseStart: Color(red: 0.16, green: 0.11, blue: 0.28),
            baseMid: Color(red: 0.11, green: 0.10, blue: 0.22),
            baseEnd: Color(red: 0.18, green: 0.10, blue: 0.20),
            orbPrimary: Color(red: 0.52, green: 0.38, blue: 0.98),
            orbSecondary: Color(red: 0.92, green: 0.32, blue: 0.62),
            orbWarm: Color(red: 0.94, green: 0.50, blue: 0.34),
            accent: Color(red: 0.46, green: 0.44, blue: 0.98)
        ),
        TvAmbientPreset(
            id: "ocean",
            name: "深海晨雾",
            subtitle: "冰川海湾与蔚蓝天际",
            baseStart: Color(red: 0.06, green: 0.16, blue: 0.28),
            baseMid: Color(red: 0.06, green: 0.11, blue: 0.21),
            baseEnd: Color(red: 0.05, green: 0.14, blue: 0.21),
            orbPrimary: Color(red: 0.14, green: 0.64, blue: 0.98),
            orbSecondary: Color(red: 0.08, green: 0.78, blue: 0.88),
            orbWarm: Color(red: 0.26, green: 0.40, blue: 0.84),
            accent: Color(red: 0.20, green: 0.58, blue: 0.98)
        ),
        TvAmbientPreset(
            id: "amber",
            name: "暖金影院",
            subtitle: "胡桃木暖灯与胶片琥珀",
            baseStart: Color(red: 0.21, green: 0.13, blue: 0.10),
            baseMid: Color(red: 0.13, green: 0.10, blue: 0.13),
            baseEnd: Color(red: 0.17, green: 0.09, blue: 0.13),
            orbPrimary: Color(red: 0.92, green: 0.56, blue: 0.18),
            orbSecondary: Color(red: 0.82, green: 0.28, blue: 0.38),
            orbWarm: Color(red: 0.62, green: 0.42, blue: 0.22),
            accent: Color(red: 0.90, green: 0.58, blue: 0.22)
        ),
        TvAmbientPreset(
            id: "nebula",
            name: "星云紫夜",
            subtitle: "深空星尘与极夜紫罗兰",
            baseStart: Color(red: 0.16, green: 0.09, blue: 0.27),
            baseMid: Color(red: 0.09, green: 0.08, blue: 0.19),
            baseEnd: Color(red: 0.07, green: 0.14, blue: 0.24),
            orbPrimary: Color(red: 0.64, green: 0.30, blue: 0.96),
            orbSecondary: Color(red: 0.16, green: 0.62, blue: 0.90),
            orbWarm: Color(red: 0.84, green: 0.26, blue: 0.66),
            accent: Color(red: 0.56, green: 0.40, blue: 0.98)
        ),
        TvAmbientPreset(
            id: "frost",
            name: "冰川银雾",
            subtitle: "通透银灰与克制微光",
            baseStart: Color(red: 0.11, green: 0.15, blue: 0.21),
            baseMid: Color(red: 0.08, green: 0.10, blue: 0.15),
            baseEnd: Color(red: 0.10, green: 0.13, blue: 0.19),
            orbPrimary: Color(red: 0.44, green: 0.60, blue: 0.78),
            orbSecondary: Color(red: 0.28, green: 0.56, blue: 0.78),
            orbWarm: Color(red: 0.36, green: 0.44, blue: 0.58),
            accent: Color(red: 0.26, green: 0.58, blue: 0.96)
        ),
    ]

    public static func preset(for id: String) -> TvAmbientPreset {
        allPresets.first { $0.id == id } ?? allPresets[0]
    }
}

/// Multi-layered soft-glow mesh backdrop constrained strictly via `GeometryReader` so 2:3 posters never expand layout bounds.
public struct TvAmbientSoftGlowBackground: View {
    public let themeId: String
    public let intensity: String
    public let posterUrl: String
    public let posterSync: Bool

    public init(
        themeId: String = "aurora",
        intensity: String = "standard",
        posterUrl: String = "",
        posterSync: Bool = true
    ) {
        self.themeId = themeId
        self.intensity = intensity
        self.posterUrl = posterUrl
        self.posterSync = posterSync
    }

    private var gain: Double {
        switch intensity {
        case "soft": return 0.72
        case "vivid": return 1.32
        default: return 1.0
        }
    }

    public var body: some View {
        let p = TvAmbientPreset.preset(for: themeId)
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [p.baseStart, p.baseMid, p.baseEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if posterSync && !posterUrl.isEmpty {
                    RemotePosterView(url: posterUrl, title: "", cornerRadius: 0)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.20 * min(gain, 1.2))
                        .blur(radius: 78)
                }

                RadialGradient(
                    colors: [p.orbPrimary.opacity(0.46 * gain), .clear],
                    center: UnitPoint(x: 0.14, y: 0.18),
                    startRadius: 20,
                    endRadius: geo.size.width * 0.64
                )

                RadialGradient(
                    colors: [p.orbSecondary.opacity(0.42 * gain), .clear],
                    center: UnitPoint(x: 0.86, y: 0.22),
                    startRadius: 20,
                    endRadius: geo.size.width * 0.60
                )

                RadialGradient(
                    colors: [p.orbSecondary.opacity(0.24 * gain), .clear],
                    center: UnitPoint(x: 0.50, y: 0.06),
                    startRadius: 10,
                    endRadius: geo.size.width * 0.44
                )

                RadialGradient(
                    colors: [p.orbWarm.opacity(0.36 * gain), .clear],
                    center: UnitPoint(x: 0.52, y: 0.94),
                    startRadius: 30,
                    endRadius: geo.size.width * 0.66
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

/// Full-bleed edge-to-edge cinematic artwork backdrop strictly clamped by `GeometryReader`
/// for immersive series detail and episode-selection views on Apple TV.
public struct TvImmersiveArtworkBackdrop: View {
    public let posterUrl: String
    public let headers: [String: String]
    public let themeId: String
    public let intensity: String
    public let softened: Bool

    @StateObject private var loader = PosterImageLoader()

    public init(
        posterUrl: String,
        headers: [String: String] = [:],
        themeId: String = "aurora",
        intensity: String = "standard",
        softened: Bool = false
    ) {
        self.posterUrl = posterUrl
        self.headers = headers
        self.themeId = themeId
        self.intensity = intensity
        self.softened = softened
    }

    public var body: some View {
        let preset = TvAmbientPreset.preset(for: themeId)
        let darkBase = Color(red: 0.04, green: 0.06, blue: 0.11)

        GeometryReader { geo in
            ZStack {
                // Base ambient canvas guarantees rich color before or without artwork
                TvAmbientSoftGlowBackground(
                    themeId: themeId,
                    intensity: intensity,
                    posterUrl: "",
                    posterSync: false
                )
                .frame(width: geo.size.width, height: geo.size.height)

                if let cg = loader.cgImage {
                    Image(decorative: cg, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height,
                            alignment: Alignment(horizontal: .center, vertical: .top)
                        )
                        .clipped()
                        .blur(radius: softened ? 18 : 0)
                        .opacity(softened ? 0.62 : 0.92)
                }

                // Subtle theme mood glaze so Settings ambient theme still harmonizes
                LinearGradient(
                    colors: [
                        preset.baseStart.opacity(softened ? 0.56 : 0.34),
                        preset.baseMid.opacity(softened ? 0.44 : 0.18),
                        preset.baseEnd.opacity(softened ? 0.52 : 0.24),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Left-to-right editorial contrast scrim keeping right artwork vibrant
                LinearGradient(
                    stops: softened
                        ? [
                            .init(color: darkBase.opacity(0.84), location: 0.0),
                            .init(color: darkBase.opacity(0.68), location: 0.5),
                            .init(color: darkBase.opacity(0.56), location: 1.0),
                        ]
                        : [
                            .init(color: darkBase.opacity(0.95), location: 0.0),
                            .init(color: darkBase.opacity(0.84), location: 0.30),
                            .init(color: darkBase.opacity(0.46), location: 0.54),
                            .init(color: darkBase.opacity(0.14), location: 0.78),
                            .init(color: darkBase.opacity(0.06), location: 1.0),
                        ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                // Top & bottom cinema vignette melting smoothly into the lower dock
                LinearGradient(
                    stops: softened
                        ? [
                            .init(color: darkBase.opacity(0.44), location: 0.0),
                            .init(color: darkBase.opacity(0.68), location: 0.36),
                            .init(color: darkBase.opacity(0.94), location: 1.0),
                        ]
                        : [
                            .init(color: darkBase.opacity(0.56), location: 0.0),
                            .init(color: darkBase.opacity(0.08), location: 0.20),
                            .init(color: darkBase.opacity(0.24), location: 0.48),
                            .init(color: darkBase.opacity(0.82), location: 0.72),
                            .init(color: darkBase.opacity(0.96), location: 1.0),
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            loader.load(urlString: posterUrl, headers: headers)
        }
        .onChange(of: posterUrl) { newUrl in
            loader.load(urlString: newUrl, headers: headers)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

public enum TvTheme {
    public static let background = Color(red: 0.06, green: 0.10, blue: 0.16)
    public static let surface = Color.white.opacity(0.095)
    public static let elevatedSurface = Color.white.opacity(0.135)
    public static let glassFill = Color.white.opacity(0.13)
    public static let glassStroke = Color.white.opacity(0.24)
    public static let accent = Color(red: 0.22, green: 0.56, blue: 0.98)
    public static let gold = Color(red: 0.96, green: 0.76, blue: 0.28)
    public static let secondaryText = Color(white: 0.80)
    public static let mutedText = Color(white: 0.58)
    public static let darkInk = Color(red: 0.04, green: 0.06, blue: 0.10)
}

/// Properly scaled 10-foot living-room typography for 1920x1080 Apple TV.
public enum TvFont {
    public static let cinemaTitle = Font.system(size: 52, weight: .bold)
    public static let heroTitle = Font.system(size: 44, weight: .bold)
    public static let pageTitle = Font.system(size: 32, weight: .bold)
    public static let sectionTitle = Font.system(size: 26, weight: .bold)
    public static let cardTitle = Font.system(size: 20, weight: .semibold)
    public static let button = Font.system(size: 23, weight: .semibold)
    public static let buttonSmall = Font.system(size: 19, weight: .semibold)
    public static let body = Font.system(size: 19, weight: .regular)
    public static let input = Font.system(size: 26, weight: .semibold)
    public static let caption = Font.system(size: 16, weight: .medium)
    public static let badge = Font.system(size: 14, weight: .bold)
}

/// Official Marco Movie brand lockup rendering the 3D metallic film-ribbon `M` mark (`BrandLogoMark`)
/// inside a sleek frosted-dark squircle alongside the signature two-tone `Marco Movie` wordmark.
public struct MarcoBrandLogo: View {
    public var iconSize: CGFloat
    public var fontSize: CGFloat
    public var stacked: Bool

    public init(iconSize: CGFloat = 44, fontSize: CGFloat = 26, stacked: Bool = false) {
        self.iconSize = iconSize
        self.fontSize = fontSize
        self.stacked = stacked
    }

    @ViewBuilder
    private var markTile: some View {
        let radius = iconSize * 0.25
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.16, blue: 0.24).opacity(0.92),
                            Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.94),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            #if canImport(UIKit)
            if let uiImage = UIImage(named: "BrandLogoMark") {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: iconSize * 0.80, height: iconSize * 0.80)
            } else {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: iconSize * 0.46, weight: .bold))
                    .foregroundColor(.white)
            }
            #else
            Image(systemName: "film.stack.fill")
                .font(.system(size: iconSize * 0.46, weight: .bold))
                .foregroundColor(.white)
            #endif
        }
        .frame(width: iconSize, height: iconSize)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 10, x: 0, y: 4)
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Marco")
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(Color(red: 0.97, green: 0.98, blue: 0.99))
            Text(" Movie")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(Color(red: 0.76, green: 0.82, blue: 0.90))
        }
        .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 2)
    }

    public var body: some View {
        if stacked {
            VStack(spacing: 14) {
                markTile
                wordmark
            }
        } else {
            HStack(spacing: max(10, iconSize * 0.26)) {
                markTile
                wordmark
            }
        }
    }
}

private struct TvCardFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct TvTileFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    public var tvCardFocused: Bool {
        get { self[TvCardFocusedKey.self] }
        set { self[TvCardFocusedKey.self] = newValue }
    }

    public var tvTileFocused: Bool {
        get { self[TvTileFocusedKey.self] }
        set { self[TvTileFocusedKey.self] = newValue }
    }
}

/// Generous 10-foot frosted-glass capsule button style for category tabs, toolbars, and primary actions.
public struct TvPillButtonStyle: ButtonStyle {
    public var prominent: Bool
    public var active: Bool
    public var compact: Bool
    public var destructive: Bool
    public var fullWidth: Bool

    public init(
        prominent: Bool = false,
        active: Bool = false,
        compact: Bool = false,
        destructive: Bool = false,
        fullWidth: Bool = false
    ) {
        self.prominent = prominent
        self.active = active
        self.compact = compact
        self.destructive = destructive
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillBody(
            configuration: configuration,
            prominent: prominent,
            active: active,
            compact: compact,
            destructive: destructive,
            fullWidth: fullWidth
        )
    }

    private struct PillBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        let configuration: Configuration
        let prominent: Bool
        let active: Bool
        let compact: Bool
        let destructive: Bool
        let fullWidth: Bool

        private var fgColor: Color {
            if !isEnabled {
                return Color.white.opacity(0.38)
            }
            if isFocused {
                return destructive ? .white : TvTheme.darkInk
            }
            if destructive {
                return Color(red: 1.0, green: 0.68, blue: 0.68)
            }
            if prominent || active {
                return .white
            }
            return Color(white: 0.95)
        }

        private var bgFill: Color {
            if !isEnabled {
                return Color.white.opacity(0.06)
            }
            if isFocused {
                return destructive ? Color.red : Color.white
            }
            if destructive {
                return Color.red.opacity(0.22)
            }
            if prominent || active {
                return TvTheme.accent
            }
            return TvTheme.glassFill
        }

        private var borderStroke: Color {
            if isFocused {
                return Color.white
            }
            if destructive {
                return Color.red.opacity(0.46)
            }
            if prominent || active {
                return Color.white.opacity(0.38)
            }
            return TvTheme.glassStroke
        }

        var body: some View {
            configuration.label
                .font(compact ? TvFont.buttonSmall : TvFont.button)
                .lineLimit(1)
                .foregroundColor(fgColor)
                .padding(.horizontal, compact ? 22 : 32)
                .padding(.vertical, compact ? 11 : 15)
                .frame(minWidth: (compact || fullWidth) ? nil : 112, maxWidth: fullWidth ? .infinity : nil)
                .background(Capsule().fill(bgFill))
                .overlay(
                    Capsule()
                        .strokeBorder(borderStroke, lineWidth: isFocused ? 2.6 : 1.3)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.045 : 1.0))
                .shadow(
                    color: isFocused ? Color.black.opacity(0.45) : Color.black.opacity(0.18),
                    radius: isFocused ? 18 : 8,
                    x: 0,
                    y: isFocused ? 8 : 3
                )
                .animation(.easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Clean continuous rounded-rectangle tile button for episode cells, keyboard keys, drive cards, and channel rows.
public struct TvTileButtonStyle: ButtonStyle {
    public var active: Bool
    public var cornerRadius: CGFloat
    public var preserveColors: Bool

    public init(
        active: Bool = false,
        cornerRadius: CGFloat = 14,
        preserveColors: Bool = false
    ) {
        self.active = active
        self.cornerRadius = cornerRadius
        self.preserveColors = preserveColors
    }

    public func makeBody(configuration: Configuration) -> some View {
        TileBody(
            configuration: configuration,
            active: active,
            cornerRadius: cornerRadius,
            preserveColors: preserveColors
        )
    }

    private struct TileBody: View {
        @Environment(\.isFocused) private var isFocused

        let configuration: Configuration
        let active: Bool
        let cornerRadius: CGFloat
        let preserveColors: Bool

        private var bgFill: Color {
            if preserveColors {
                if isFocused {
                    return TvTheme.accent.opacity(0.34)
                }
                return active ? TvTheme.accent.opacity(0.24) : Color.white.opacity(0.10)
            }
            if isFocused {
                return .white
            }
            return active ? TvTheme.accent : Color.white.opacity(0.10)
        }

        private var strokeColor: Color {
            if isFocused {
                return .white
            }
            return active ? Color.white.opacity(0.42) : TvTheme.glassStroke
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundColor((!preserveColors && isFocused) ? TvTheme.darkInk : .white)
                .background(shape.fill(bgFill))
                .overlay(
                    shape.strokeBorder(strokeColor, lineWidth: isFocused ? 2.5 : (active ? 1.5 : 1.1))
                )
                .clipShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.035 : 1.0))
                .shadow(
                    color: isFocused ? Color.black.opacity(0.48) : Color.clear,
                    radius: 18,
                    x: 0,
                    y: 8
                )
                .animation(.easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Purpose-built 10-foot episode card button style for Apple TV immersive detail rails
/// and the dedicated episode selection grid. Propagates focus state via `tvTileFocused`
/// so inner badges, episode indices, and progress bars dynamically invert contrast.
public struct TvEpisodeTileButtonStyle: ButtonStyle {
    public var active: Bool
    public var cornerRadius: CGFloat

    public init(active: Bool = false, cornerRadius: CGFloat = 18) {
        self.active = active
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        EpisodeTileBody(
            configuration: configuration,
            active: active,
            cornerRadius: cornerRadius
        )
    }

    private struct EpisodeTileBody: View {
        @Environment(\.isFocused) private var isFocused

        let configuration: Configuration
        let active: Bool
        let cornerRadius: CGFloat

        private var bgFill: Color {
            if isFocused {
                return .white
            }
            if active {
                return TvTheme.accent.opacity(0.30)
            }
            return Color(red: 0.09, green: 0.12, blue: 0.19).opacity(0.72)
        }

        private var strokeColor: Color {
            if isFocused {
                return .white
            }
            if active {
                return TvTheme.accent.opacity(0.92)
            }
            return Color.white.opacity(0.18)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .environment(\.tvTileFocused, isFocused)
                .foregroundColor(isFocused ? TvTheme.darkInk : .white)
                .background(shape.fill(bgFill))
                .overlay(
                    shape.strokeBorder(
                        strokeColor,
                        lineWidth: isFocused ? 2.6 : (active ? 1.7 : 1.1)
                    )
                )
                .clipShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.038 : 1.0))
                .shadow(
                    color: isFocused ? Color.black.opacity(0.56) : Color.black.opacity(0.22),
                    radius: isFocused ? 22 : 8,
                    x: 0,
                    y: isFocused ? 10 : 4
                )
                .animation(.easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Focusable poster card style that highlights ONLY the poster image rim without wrapping the title in a gray box.
public struct TvPosterButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PosterBody(configuration: configuration)
    }

    private struct PosterBody: View {
        @Environment(\.isFocused) private var isFocused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .environment(\.tvCardFocused, isFocused)
                .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.045 : 1.0))
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Generous focusable toggle chip replacing bloated native tvOS `Toggle` rows.
public struct TvToggleChip: View {
    public let title: String
    @Binding public var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .bold))
                Text(title)
            }
        }
        .buttonStyle(TvPillButtonStyle(active: isOn, compact: true))
    }
}

/// Clean frosted-glass focusable text input box avoiding tvOS's nested gray `UITextField` chrome and small clamped fonts,
/// while opening the native tvOS Siri Voice / Continuity Keyboard sheet on press.
public struct TvGlassInputField: View {
    public let title: String
    public let placeholder: String
    @Binding public var text: String
    public var systemImage: String?
    public var isSecure: Bool
    public var large: Bool
    public var showVoiceBadge: Bool
    public var onSubmit: (() -> Void)?

    @State private var showEditor = false
    @State private var draft = ""

    public init(
        title: String,
        placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        isSecure: Bool = false,
        large: Bool = false,
        showVoiceBadge: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.systemImage = systemImage
        self.isSecure = isSecure
        self.large = large
        self.showVoiceBadge = showVoiceBadge
        self.onSubmit = onSubmit
    }

    private var displayValue: String {
        guard !text.isEmpty else { return placeholder }
        if isSecure {
            return String(repeating: "•", count: min(max(text.count, 6), 16))
        }
        return text
    }

    public var body: some View {
        Button {
            draft = text
            showEditor = true
        } label: {
            HStack(spacing: large ? 14 : 10) {
                if let icon = systemImage {
                    Image(systemName: icon)
                        .font(.system(size: large ? 24 : 19, weight: .bold))
                        .foregroundColor(text.isEmpty ? TvTheme.secondaryText : .white)
                }

                Text(displayValue)
                    .font(
                        text.isEmpty
                            ? .system(size: large ? 22 : 19, weight: .medium)
                            : .system(size: large ? 28 : 21, weight: large ? .bold : .semibold)
                    )
                    .foregroundColor(text.isEmpty ? TvTheme.mutedText : .white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if showVoiceBadge {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("键盘/语音")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(TvTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, large ? 22 : 18)
            .padding(.vertical, large ? 16 : 14)
            .frame(maxWidth: .infinity, minHeight: large ? 68 : 56, alignment: .leading)
        }
        .buttonStyle(TvTileButtonStyle(active: !text.isEmpty && large, cornerRadius: large ? 18 : 14, preserveColors: true))
        #if os(tvOS)
        .fullScreenCover(isPresented: $showEditor) {
            TvTextInputModal(
                title: title,
                placeholder: placeholder,
                text: $draft,
                isSecure: isSecure,
                onConfirm: {
                    text = draft
                    showEditor = false
                    onSubmit?()
                },
                onCancel: {
                    showEditor = false
                }
            )
        }
        #else
        .sheet(isPresented: $showEditor) {
            TvTextInputModal(
                title: title,
                placeholder: placeholder,
                text: $draft,
                isSecure: isSecure,
                onConfirm: {
                    text = draft
                    showEditor = false
                    onSubmit?()
                },
                onCancel: {
                    showEditor = false
                }
            )
        }
        #endif
    }
}

private struct TvTextInputModal: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(title)
                .font(TvFont.pageTitle)
                .foregroundColor(.white)

            Text("支持 Siri 遥控器语音听写、iPhone 隔空键盘或屏幕软键盘输入")
                .font(TvFont.body)
                .foregroundColor(TvTheme.secondaryText)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(TvFont.input)
            .frame(maxWidth: 780)
            .onSubmit {
                onConfirm()
            }

            HStack(spacing: 18) {
                Button("清空") {
                    text = ""
                }
                .buttonStyle(TvPillButtonStyle())

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(TvPillButtonStyle())

                Button("完成") {
                    onConfirm()
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
            }

            Spacer()
        }
        .padding(56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TvAmbientSoftGlowBackground())
        .tvExitHandler {
            onCancel()
        }
    }
}

extension View {
    @ViewBuilder
    public func tvCardButtonStyle() -> some View {
        self.buttonStyle(TvPosterButtonStyle())
    }

    @ViewBuilder
    public func tvAmbientPageBackground(_ appModel: AppViewModel) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                TvAmbientSoftGlowBackground(
                    themeId: appModel.preferences.ambientTheme,
                    intensity: appModel.preferences.ambientIntensity,
                    posterUrl: appModel.backdropPosterUrl,
                    posterSync: appModel.preferences.ambientPosterSync
                )
            )
    }

    @ViewBuilder
    public func tvExitHandler(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

/// Crisp QR code generator backed by `CoreImage`'s `CIQRCodeGenerator` rendered with `.interpolation(.none)`.
public struct QrCodeImageView: View {
    public let payload: String
    public let size: CGFloat

    public init(payload: String, size: CGFloat = 220) {
        self.payload = payload
        self.size = size
    }

    public var body: some View {
        if let cgImage = Self.generateCGImage(from: payload) {
            Image(decorative: cgImage, scale: 1.0, orientation: .up)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TvTheme.elevatedSurface)
                .frame(width: size + 32, height: size + 32)
                .overlay(
                    Text("二维码生成中…")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                )
        }
    }

    public static func generateCGImage(from string: String) -> CGImage? {
        guard !string.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

/// Shared poster image cache & loader supporting per-site `Referer` and `User-Agent` headers.
@MainActor
public final class PosterImageLoader: ObservableObject {
    @Published public private(set) var cgImage: CGImage?
    @Published public private(set) var didFail = false

    private static let urlSession: URLSession = {
        let cache = URLCache(
            memoryCapacity: 48 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024,
            directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MarcoPosterCache", isDirectory: true)
        )
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 12
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private var currentKey = ""
    private var loadTask: Task<Void, Never>?

    public init() {}

    public func load(urlString: String, headers: [String: String] = [:]) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cgImage = nil
            didFail = true
            return
        }
        if currentKey == trimmed && (cgImage != nil || didFail) {
            return
        }
        currentKey = trimmed
        didFail = false
        loadTask?.cancel()

        loadTask = Task {
            guard let url = URL(string: CmsParser.normalizeUrl(trimmed)) else {
                self.didFail = true
                return
            }
            var req = URLRequest(url: url)
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            if req.value(forHTTPHeaderField: "User-Agent") == nil {
                req.setValue(CmsClient.defaultSafariUserAgent, forHTTPHeaderField: "User-Agent")
            }
            if req.value(forHTTPHeaderField: "Referer") == nil,
               let scheme = url.scheme, let host = url.host
            {
                req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
            }

            do {
                let (data, resp) = try await Self.urlSession.data(for: req)
                guard !Task.isCancelled else { return }
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.didFail = true
                    return
                }
                if let decoded = Self.decodeCGImage(from: data) {
                    self.cgImage = decoded
                } else {
                    self.didFail = true
                }
            } catch {
                if !Task.isCancelled {
                    self.didFail = true
                }
            }
        }
    }

    public func cancel() {
        loadTask?.cancel()
    }

    nonisolated private static func decodeCGImage(from data: Data) -> CGImage? {
        #if canImport(UIKit)
        return UIImage(data: data)?.cgImage
        #elseif canImport(AppKit)
        guard let nsImg = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImg.size)
        return nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}

public struct RemotePosterView: View {
    public let url: String
    public let title: String
    public let headers: [String: String]
    public let cornerRadius: CGFloat

    @StateObject private var loader = PosterImageLoader()

    public init(
        url: String,
        title: String,
        headers: [String: String] = [:],
        cornerRadius: CGFloat = 16
    ) {
        self.url = url
        self.title = title
        self.headers = headers
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let cg = loader.cgImage {
                Image(decorative: cg, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 26))
                        .foregroundColor(TvTheme.mutedText)
                    if !title.isEmpty {
                        Text(title)
                            .font(TvFont.caption)
                            .foregroundColor(TvTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            loader.load(urlString: url, headers: headers)
        }
        .onChange(of: url) { newUrl in
            loader.load(urlString: newUrl, headers: headers)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

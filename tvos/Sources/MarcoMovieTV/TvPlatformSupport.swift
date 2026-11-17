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

public enum TvTheme {
    public static let background = Color(red: 0.05, green: 0.06, blue: 0.09)
    public static let surface = Color(red: 0.11, green: 0.13, blue: 0.18)
    public static let elevatedSurface = Color(red: 0.16, green: 0.19, blue: 0.26)
    public static let accent = Color(red: 0.25, green: 0.56, blue: 0.98)
    public static let gold = Color(red: 0.96, green: 0.75, blue: 0.26)
    public static let secondaryText = Color(white: 0.72)
    public static let mutedText = Color(white: 0.50)
}

extension View {
    @ViewBuilder
    public func tvCardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
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

    public init(payload: String, size: CGFloat = 280) {
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
                .padding(18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TvTheme.elevatedSurface)
                .frame(width: size, height: size)
                .overlay(
                    Text("二维码生成中…")
                        .font(.footnote)
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
                        colors: [TvTheme.elevatedSurface, TvTheme.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let cg = loader.cgImage {
                Image(decorative: cg, scale: 1.0, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundColor(TvTheme.mutedText)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(TvTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            loader.load(urlString: url, headers: headers)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

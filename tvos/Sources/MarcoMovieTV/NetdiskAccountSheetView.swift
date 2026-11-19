// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct NetdiskAccountSheetView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeDriveKey: String = "quark"
    @State private var qrSession: NetdiskQrSession?
    @State private var isGeneratingQr = false
    @State private var pollState: NetdiskPollState = .waiting
    @State private var statusText: String = "正在准备扫码会话…"
    @State private var pollTask: Task<Void, Never>?

    private let qualityOptions: [(code: String, label: String)] = [
        ("auto", "自动优选"),
        ("4k_hdr", "4K 原画 HDR"),
        ("1080p", "1080P 流畅"),
    ]

    private let kernelOptions: [(code: String, label: String)] = [
        ("range_proxy", "6 线程分片加速（24 MiB 内存池）"),
        ("avkit", "AVKit 原生直连"),
    ]

    public init() {}

    private var currentDrive: NetdiskDriveInfo {
        NetdiskDriveInfo.info(for: activeDriveKey) ?? NetdiskDriveInfo.allDrives[0]
    }

    private var isCurrentDriveLoggedIn: Bool {
        appModel.loggedInNetdiskDrives.contains(currentDrive.key)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            headerRow
            driveCardsRow
            qrAndStatusPanel
            qualityAndKernelPanel
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            TvAmbientSoftGlowBackground(
                themeId: appModel.preferences.ambientTheme,
                intensity: appModel.preferences.ambientIntensity,
                posterUrl: appModel.backdropPosterUrl,
                posterSync: appModel.preferences.ambientPosterSync
            )
        )
        .onAppear {
            activeDriveKey = appModel.selectedNetdiskDriveKey
            beginQrFlow(for: activeDriveKey)
        }
        .onDisappear {
            cancelPolling()
        }
        .tvExitHandler {
            cancelPolling()
            dismiss()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 18) {
            MarcoBrandLogo(iconSize: 42, fontSize: 24)

            Rectangle()
                .fill(TvTheme.glassStroke)
                .frame(width: 1.5, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text("4K 网盘扫码授权与多线程加速")
                    .font(TvFont.pageTitle)
                    .foregroundColor(.white)
                Text("会话凭据仅加密保存在 Apple TV 本地钥匙串，绝不写入公开备份文件或跨域名泄露。")
                    .font(TvFont.caption)
                    .foregroundColor(TvTheme.secondaryText)
            }
            Spacer()
            Button {
                cancelPolling()
                dismiss()
                appModel.openLanQrModal()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                    Text("手机网页粘贴推送")
                }
            }
            .buttonStyle(TvPillButtonStyle())

            Button("完成") {
                cancelPolling()
                dismiss()
            }
            .buttonStyle(TvPillButtonStyle(prominent: true))
        }
    }

    // MARK: - 4 Drive Cards

    private var driveCardsRow: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)
        return LazyVGrid(columns: cols, spacing: 16) {
            ForEach(NetdiskDriveInfo.allDrives) { drive in
                let selected = drive.key == activeDriveKey
                let loggedIn = appModel.loggedInNetdiskDrives.contains(drive.key)
                Button {
                    selectDrive(drive.key)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(drive.tvName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text(loggedIn ? "● 已登录" : "未登录")
                                .font(TvFont.badge)
                                .foregroundColor(loggedIn ? .green : TvTheme.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background((loggedIn ? Color.green : Color.white).opacity(0.14))
                                .clipShape(Capsule())
                        }
                        HStack {
                            Text(drive.providerName)
                                .font(TvFont.caption)
                                .foregroundColor(TvTheme.secondaryText)
                            Spacer()
                            Text(drive.linePrefix)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(TvTheme.gold)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .buttonStyle(TvTileButtonStyle(active: selected, cornerRadius: 16, preserveColors: true))
            }
        }
    }

    // MARK: - QR Panel & Polling Controls

    private var qrAndStatusPanel: some View {
        HStack(alignment: .center, spacing: 36) {
            ZStack {
                if let session = qrSession, !session.qrUrl.isEmpty {
                    QrCodeImageView(payload: session.qrUrl, size: 205)
                        .opacity(pollState == .expired ? 0.35 : 1.0)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(TvTheme.elevatedSurface)
                        .frame(width: 237, height: 237)
                        .overlay(
                            VStack(spacing: 10) {
                                if isGeneratingQr {
                                    ProgressView()
                                }
                                Text(isGeneratingQr ? "正在请求扫码令牌…" : "点击右侧刷新二维码")
                                    .font(TvFont.caption)
                                    .foregroundColor(TvTheme.secondaryText)
                            }
                        )
                }

                if pollState == .expired {
                    Text("二维码已失效")
                        .font(TvFont.button)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("\(currentDrive.tvName) · \(currentDrive.providerName)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    if isCurrentDriveLoggedIn {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("钥匙串凭据有效")
                        }
                        .font(TvFont.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.14))
                        .clipShape(Capsule())
                    }
                }

                Text(currentDrive.appHint)
                    .font(TvFont.body)
                    .foregroundColor(TvTheme.secondaryText)

                HStack(spacing: 9) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 9, height: 9)
                    Text(statusText)
                        .font(TvFont.caption)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(TvTheme.elevatedSurface)
                .overlay(Capsule().strokeBorder(TvTheme.glassStroke, lineWidth: 1))
                .clipShape(Capsule())

                HStack(spacing: 12) {
                    Button {
                        beginQrFlow(for: currentDrive.key)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text(isCurrentDriveLoggedIn ? "重新扫码换绑" : "刷新二维码")
                        }
                    }
                    .buttonStyle(TvPillButtonStyle(prominent: true))
                    .disabled(isGeneratingQr)

                    if isCurrentDriveLoggedIn {
                        Button {
                            appModel.logoutNetdisk(driveKey: currentDrive.key)
                            statusText = "已退出 \(currentDrive.tvName) 登录状态"
                            beginQrFlow(for: currentDrive.key)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("退出登录")
                            }
                        }
                        .buttonStyle(TvPillButtonStyle(destructive: true))
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(26)
        .background(TvTheme.surface.opacity(0.80))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(TvTheme.glassStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Quality & Range Proxy Kernel Picker

    private var qualityAndKernelPanel: some View {
        HStack(spacing: 36) {
            HStack(spacing: 12) {
                Text("云盘画质偏好")
                    .font(TvFont.button)
                    .foregroundColor(TvTheme.secondaryText)

                ForEach(qualityOptions, id: \.code) { opt in
                    let active = appModel.preferences.netdiskQuality == opt.code
                    Button(opt.label) {
                        appModel.updatePlaybackPreferences { $0.netdiskQuality = opt.code }
                    }
                    .buttonStyle(TvPillButtonStyle(active: active, compact: true))
                }
            }

            Rectangle()
                .fill(TvTheme.glassStroke)
                .frame(width: 1, height: 28)

            HStack(spacing: 12) {
                Text("加速内核")
                    .font(TvFont.button)
                    .foregroundColor(TvTheme.secondaryText)

                ForEach(kernelOptions, id: \.code) { opt in
                    let active = appModel.preferences.playerKernel == opt.code
                    Button(opt.label) {
                        appModel.updatePlaybackPreferences { $0.playerKernel = opt.code }
                    }
                    .buttonStyle(TvPillButtonStyle(active: active, compact: true))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(TvTheme.surface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(TvTheme.glassStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusIndicatorColor: Color {
        switch pollState {
        case .confirmed: return .green
        case .scanned: return TvTheme.gold
        case .expired, .error: return .orange
        case .waiting: return TvTheme.accent
        }
    }

    // MARK: - Polling State Machine

    private func selectDrive(_ driveKey: String) {
        guard driveKey != activeDriveKey || qrSession == nil else { return }
        activeDriveKey = driveKey
        appModel.selectedNetdiskDriveKey = driveKey
        beginQrFlow(for: driveKey)
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func beginQrFlow(for driveKey: String) {
        cancelPolling()
        qrSession = nil
        isGeneratingQr = true
        pollState = .waiting
        statusText = "正在连接 \(NetdiskDriveInfo.info(for: driveKey)?.providerName ?? "网盘")生成二维码…"

        let service = appModel.netdiskService
        pollTask = Task {
            do {
                let created = try await service.startQrSession(driveKey: driveKey)
                guard !Task.isCancelled else { return }
                qrSession = created
                isGeneratingQr = false
                pollState = .waiting
                statusText = "请使用手机 App 扫描左侧二维码（每 2 秒自动检测授权结果）"

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { break }
                    let result = await service.pollQrSession(created)
                    guard !Task.isCancelled else { break }

                    pollState = result.state
                    statusText = result.message

                    if result.state == .confirmed {
                        do {
                            try appModel.saveNetdiskCredential(driveKey: driveKey, credential: result.credential)
                            statusText = "授权已完成，支持 4K 原画分片直连播放"
                        } catch {
                            pollState = .error
                            statusText = error.localizedDescription
                        }
                        break
                    }
                    if result.state == .expired {
                        break
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                isGeneratingQr = false
                pollState = .error
                statusText = "二维码生成失败：\(error.localizedDescription)"
            }
        }
    }
}

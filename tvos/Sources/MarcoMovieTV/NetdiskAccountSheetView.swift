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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerRow
                driveCardsRow
                qrAndStatusPanel
                qualityAndKernelPanel
            }
            .padding(44)
        }
        .background(TvTheme.background)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("4K 网盘扫码授权与多线程加速")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("会话凭据仅加密保存在 Apple TV 本地钥匙串，绝不写入公开备份文件或跨域名泄露。")
                    .font(.caption)
                    .foregroundColor(TvTheme.secondaryText)
            }
            Spacer()
            Button {
                cancelPolling()
                dismiss()
                appModel.openLanQrModal()
            } label: {
                Label("手机网页粘贴推送", systemImage: "iphone.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)

            Button("完成") {
                cancelPolling()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(TvTheme.accent)
        }
    }

    // MARK: - 4 Drive Cards

    private var driveCardsRow: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
        return LazyVGrid(columns: cols, spacing: 18) {
            ForEach(NetdiskDriveInfo.allDrives) { drive in
                let selected = drive.key == activeDriveKey
                let loggedIn = appModel.loggedInNetdiskDrives.contains(drive.key)
                Button {
                    selectDrive(drive.key)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(drive.tvName)
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            Spacer()
                            Text(loggedIn ? "已登录" : "未登录")
                                .font(.caption2.bold())
                                .foregroundColor(loggedIn ? .green : TvTheme.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    (loggedIn ? Color.green : Color.white).opacity(0.16)
                                )
                                .clipShape(Capsule())
                        }
                        HStack {
                            Text(drive.providerName)
                                .font(.caption)
                                .foregroundColor(TvTheme.secondaryText)
                            Spacer()
                            Text(drive.linePrefix)
                                .font(.caption2.monospaced())
                                .foregroundColor(TvTheme.gold)
                        }
                    }
                    .padding(18)
                    .background(selected ? TvTheme.accent.opacity(0.32) : TvTheme.elevatedSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selected ? TvTheme.accent : Color.clear, lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .tvCardButtonStyle()
            }
        }
    }

    // MARK: - QR Panel & Polling Controls

    private var qrAndStatusPanel: some View {
        HStack(alignment: .center, spacing: 40) {
            ZStack {
                if let session = qrSession, !session.qrUrl.isEmpty {
                    QrCodeImageView(payload: session.qrUrl, size: 250)
                        .opacity(pollState == .expired ? 0.35 : 1.0)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(TvTheme.elevatedSurface)
                        .frame(width: 286, height: 286)
                        .overlay(
                            VStack(spacing: 12) {
                                if isGeneratingQr {
                                    ProgressView()
                                }
                                Text(isGeneratingQr ? "正在请求官方扫码令牌…" : "点击右侧刷新获取二维码")
                                    .font(.caption)
                                    .foregroundColor(TvTheme.secondaryText)
                            }
                        )
                }

                if pollState == .expired {
                    Text("二维码已失效")
                        .font(.headline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text("\(currentDrive.tvName) · \(currentDrive.providerName)")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    if isCurrentDriveLoggedIn {
                        Label("钥匙串凭据有效", systemImage: "checkmark.seal.fill")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    }
                }

                Text(currentDrive.appHint)
                    .font(.callout)
                    .foregroundColor(TvTheme.secondaryText)

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 10, height: 10)
                    Text(statusText)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(TvTheme.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 16) {
                    Button {
                        beginQrFlow(for: currentDrive.key)
                    } label: {
                        Label(isCurrentDriveLoggedIn ? "重新扫码换绑" : "刷新二维码", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TvTheme.accent)
                    .disabled(isGeneratingQr)

                    if isCurrentDriveLoggedIn {
                        Button(role: .destructive) {
                            appModel.logoutNetdisk(driveKey: currentDrive.key)
                            statusText = "已退出 \(currentDrive.tvName) 登录状态"
                            beginQrFlow(for: currentDrive.key)
                        } label: {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Spacer()
        }
        .padding(28)
        .background(TvTheme.surface.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Quality & Range Proxy Kernel Picker

    private var qualityAndKernelPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                Text("云盘画质偏好：")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)

                ForEach(qualityOptions, id: \.code) { opt in
                    let active = appModel.preferences.netdiskQuality == opt.code
                    Button(opt.label) {
                        appModel.updatePlaybackPreferences { $0.netdiskQuality = opt.code }
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? TvTheme.accent : .gray)
                }

                Spacer()
            }

            HStack(spacing: 20) {
                Text("流媒体加速内核：")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)

                ForEach(kernelOptions, id: \.code) { opt in
                    let active = appModel.preferences.playerKernel == opt.code
                    Button(opt.label) {
                        appModel.updatePlaybackPreferences { $0.playerKernel = opt.code }
                    }
                    .buttonStyle(.bordered)
                    .tint(active ? TvTheme.accent : .gray)
                }

                Spacer()
            }
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

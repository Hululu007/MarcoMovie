// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var appModel: AppViewModel

    @State private var manualSubUrl = ""
    @State private var manualSubName = ""
    @State private var isImportingUrl = false
    @State private var showBackupPreviewSheet = false
    @State private var exportedBackupPreview = ""
    @State private var showResetConfirmation = false

    private let speedChoices: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("设置与多端同步")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                lanQrAndManualUrlSection
                multiDepotAndSitesSection
                webdavCloudSyncSection
                playbackPreferencesSection
                backupAndResetSection
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
        }
        .sheet(isPresented: $showBackupPreviewSheet) {
            BackupPreviewModal(jsonText: exportedBackupPreview)
        }
        .confirmationDialog(
            "确认重置全部订阅、收藏、观看历史与云同步凭据？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认重置", role: .destructive) {
                try? appModel.storage.resetAllData()
                appModel.reloadLocalState()
                appModel.statusBannerMessage = "已清空本地与钥匙串锚点数据"
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 1. LAN QR Push & Manual URL Input

    private var lanQrAndManualUrlSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. 订阅配置导入（推荐手机扫码免输入）")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 18) {
                Button {
                    appModel.openLanQrModal()
                } label: {
                    Label("打开手机扫码推送配置 / 备份二维码", systemImage: "qrcode.viewfinder")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(TvTheme.accent)

                Text("支持一键推送多仓、TVBox JSON、M3U/TXT 直播列表及 marco-movie-backup.json")
                    .font(.caption)
                    .foregroundColor(TvTheme.secondaryText)
            }

            HStack(spacing: 14) {
                TextField("手动粘贴 HTTP(S) 订阅或多仓地址", text: $manualSubUrl)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextField("备注名（可选）", text: $manualSubName)
                    .textFieldStyle(.plain)
                    .frame(width: 240)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Task {
                        isImportingUrl = true
                        defer { isImportingUrl = false }
                        do {
                            try await appModel.importSubscriptionFromUrl(manualSubUrl, name: manualSubName)
                            manualSubUrl = ""
                            manualSubName = ""
                            appModel.statusBannerMessage = "订阅导入成功"
                        } catch {
                            appModel.statusBannerMessage = error.localizedDescription
                        }
                    }
                } label: {
                    if isImportingUrl {
                        ProgressView()
                    } else {
                        Text("导入")
                            .padding(.horizontal, 18)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualSubUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingUrl)
            }
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 2. Multi-Depot & Site Capability Status

    private var multiDepotAndSitesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("2. 多仓与片源兼容状态")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text("可用 \(appModel.config.availableSites.count) / 共 \(appModel.config.sites.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(TvTheme.accent)
            }

            if !appModel.subscriptions.isEmpty {
                ForEach(appModel.subscriptions) { sub in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sub.name)
                                .font(.callout.weight(.semibold))
                            Text(sub.url.isEmpty ? "本地文本推送" : sub.url)
                                .font(.caption2)
                                .foregroundColor(TvTheme.mutedText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("移除", role: .destructive) {
                            appModel.storage.removeSubscription(id: sub.id)
                            appModel.reloadLocalState()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(TvTheme.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if !appModel.config.depots.isEmpty {
                Button("打开多仓与片源切换面板（共 \(appModel.config.depots.count) 个仓库）") {
                    appModel.showSiteSwitcherSheet = true
                }
                .buttonStyle(.bordered)
            }

            if !appModel.config.unsupportedSites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已自动置灰的受限片源（共 \(appModel.config.unsupportedSites.count) 个）")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(TvTheme.secondaryText)

                    ForEach(appModel.config.unsupportedSites.prefix(8)) { site in
                        HStack {
                            Text(site.name)
                                .font(.caption)
                                .foregroundColor(TvTheme.secondaryText)
                            Spacer()
                            Text(site.capabilityStatus)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .clipShape(Capsule())
                            Text(site.unsupportedReason)
                                .font(.caption2)
                                .foregroundColor(TvTheme.mutedText)
                        }
                    }
                }
                .padding(14)
                .background(TvTheme.background.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 3. WebDAV Cloud Sync

    private var webdavCloudSyncSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("3. WebDAV 云端同步（坚果云 / NAS / Alist）")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                if !appModel.webdavConfig.lastSyncStatus.isEmpty {
                    Text(appModel.webdavConfig.lastSyncStatus)
                        .font(.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }
            }

            HStack(spacing: 14) {
                TextField("WebDAV 地址（如 dav.jianguoyun.com）", text: $appModel.webdavConfig.url)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextField("账号", text: $appModel.webdavConfig.username)
                    .textFieldStyle(.plain)
                    .frame(width: 260)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                SecureField("应用密码", text: $appModel.webdavConfig.password)
                    .textFieldStyle(.plain)
                    .frame(width: 260)
                    .padding(14)
                    .background(TvTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 24) {
                Toggle("启动时自动同步", isOn: $appModel.webdavConfig.autoSync)
                Toggle("同步公开订阅源", isOn: $appModel.webdavConfig.syncSubscriptions)
                Toggle("同步观看历史与收藏", isOn: $appModel.webdavConfig.syncHistory)
                Spacer()
                Button {
                    Task { await appModel.triggerManualWebDavSync() }
                } label: {
                    if appModel.isSyncingWebDav {
                        ProgressView()
                    } else {
                        Label("保存并立即双向同步", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TvTheme.accent)
                .disabled(appModel.isSyncingWebDav)
            }
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 4. Playback Preferences

    private var playbackPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("4. 播放偏好（跳过片头片尾 / 默认倍速）")
                .font(.headline)
                .foregroundColor(.white)

            HStack(spacing: 28) {
                HStack(spacing: 10) {
                    Text("跳过片头：\(appModel.preferences.skipIntroSec) 秒")
                        .font(.callout)
                    Button("-15s") {
                        appModel.updatePlaybackPreferences { $0.skipIntroSec = max(0, $0.skipIntroSec - 15) }
                    }
                    .buttonStyle(.bordered)
                    Button("+15s") {
                        appModel.updatePlaybackPreferences { $0.skipIntroSec = min(600, $0.skipIntroSec + 15) }
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Text("跳过片尾：\(appModel.preferences.skipOutroSec) 秒")
                        .font(.callout)
                    Button("-15s") {
                        appModel.updatePlaybackPreferences { $0.skipOutroSec = max(0, $0.skipOutroSec - 15) }
                    }
                    .buttonStyle(.bordered)
                    Button("+15s") {
                        appModel.updatePlaybackPreferences { $0.skipOutroSec = min(600, $0.skipOutroSec + 15) }
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Text("默认倍速：")
                        .font(.callout)
                    ForEach(speedChoices, id: \.self) { sp in
                        Button("\(String(format: "%.2gx", sp))") {
                            appModel.updatePlaybackPreferences { $0.playSpeed = sp }
                        }
                        .buttonStyle(.bordered)
                        .tint(appModel.preferences.playSpeed == sp ? TvTheme.accent : .gray)
                    }
                }

                Toggle(
                    "自动连播下一集",
                    isOn: Binding(
                        get: { appModel.preferences.autoNext },
                        set: { val in appModel.updatePlaybackPreferences { $0.autoNext = val } }
                    )
                )
            }
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 5. Backup Preview & Factory Reset

    private var backupAndResetSection: some View {
        HStack(spacing: 20) {
            Button {
                exportedBackupPreview = (try? appModel.storage.exportBackupJson()) ?? "{}"
                showBackupPreviewSheet = true
            } label: {
                Label("预览 marco-movie-backup JSON", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("清空本地与钥匙串全部数据", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("存储策略：Keychain 压缩锚点 + Caches 自愈工作区（零 Documents 占用）")
                .font(.caption2)
                .foregroundColor(TvTheme.mutedText)
        }
        .padding(24)
        .background(TvTheme.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct BackupPreviewModal: View {
    let jsonText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("跨端备份 JSON 预览（schema: marco-movie-backup）")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            ScrollView {
                Text(jsonText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(TvTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(TvTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(40)
        .background(TvTheme.background)
    }
}

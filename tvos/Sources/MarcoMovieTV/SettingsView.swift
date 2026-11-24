// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import MarcoTVCore
import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var appModel: AppViewModel

    private enum SettingsTab: String, CaseIterable {
        case appearance = "外观与柔光"
        case sources = "订阅与片源"
        case netdisk = "4K 网盘加速"
        case webdav = "WebDAV 云同步"
        case playback = "播放与跳过"
        case backup = "备份与存储"

        var icon: String {
            switch self {
            case .appearance: return "paintbrush.pointed.fill"
            case .sources: return "square.stack.3d.up.fill"
            case .netdisk: return "externaldrive.badge.wifi"
            case .webdav: return "icloud.and.arrow.up"
            case .playback: return "slider.horizontal.3"
            case .backup: return "externaldrive.fill.badge.checkmark"
            }
        }
    }

    @State private var selectedSection: SettingsTab = .appearance
    @State private var manualSubUrl = ""
    @State private var manualSubName = ""
    @State private var isImportingUrl = false
    @State private var showBackupPreviewSheet = false
    @State private var exportedBackupPreview = ""
    @State private var showResetConfirmation = false

    private let speedChoices: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 32) {
            // Left Settings Navigation Rail
            VStack(alignment: .leading, spacing: 10) {
                Text("系统设置")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                ForEach(SettingsTab.allCases, id: \.rawValue) { item in
                    let active = selectedSection == item
                    Button {
                        selectedSection = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 22)
                            Text(item.rawValue)
                                .font(TvFont.button)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(TvTileButtonStyle(active: active, cornerRadius: 14))
                }

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    MarcoBrandLogo(iconSize: 30, fontSize: 18)
                    Text("tvOS 客厅原画端 · Keychain 自愈存储")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TvTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .frame(width: 336)

            // Right Detail Panel
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedSection {
                    case .appearance:
                        appearanceSoftGlowSection
                    case .sources:
                        lanQrAndManualUrlSection
                        multiDepotAndSitesSection
                    case .netdisk:
                        netdiskAndRangeProxySection
                    case .webdav:
                        webdavCloudSyncSection
                    case .playback:
                        playbackPreferencesSection
                    case .backup:
                        backupAndResetSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 56)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(tvOS)
        .fullScreenCover(isPresented: $showBackupPreviewSheet) {
            BackupPreviewModal(jsonText: exportedBackupPreview)
                .environmentObject(appModel)
        }
        #else
        .sheet(isPresented: $showBackupPreviewSheet) {
            BackupPreviewModal(jsonText: exportedBackupPreview)
                .environmentObject(appModel)
        }
        #endif
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

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TvTheme.surface.opacity(0.80))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(TvTheme.glassStroke, lineWidth: 1.1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 0. Soft-Glow Ambient Backdrop & Color Theme Customizer

    private var appearanceSoftGlowSection: some View {
        let currentTheme = appModel.preferences.ambientTheme
        let currentPreset = TvAmbientPreset.preset(for: currentTheme)
        return VStack(alignment: .leading, spacing: 22) {
            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("客厅全局渐变柔光主题")
                            .font(TvFont.sectionTitle)
                            .foregroundColor(.white)
                        Text("自由定制大屏背景柔光色彩，切换即时生效并持久化保存（当前：\(currentPreset.name)）")
                            .font(TvFont.caption)
                            .foregroundColor(TvTheme.secondaryText)
                    }
                    Spacer()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
                    ForEach(TvAmbientPreset.allPresets) { preset in
                        let isSelected = currentTheme == preset.id
                        Button {
                            appModel.updatePlaybackPreferences { $0.ambientTheme = preset.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                ZStack(alignment: .topTrailing) {
                                    ZStack {
                                        LinearGradient(
                                            colors: [preset.baseStart, preset.baseMid, preset.baseEnd],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        RadialGradient(
                                            colors: [preset.orbPrimary.opacity(0.78), .clear],
                                            center: UnitPoint(x: 0.22, y: 0.30),
                                            startRadius: 6,
                                            endRadius: 190
                                        )
                                        RadialGradient(
                                            colors: [preset.orbSecondary.opacity(0.72), .clear],
                                            center: UnitPoint(x: 0.82, y: 0.65),
                                            startRadius: 6,
                                            endRadius: 180
                                        )
                                    }
                                    .frame(height: 78)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                                    )

                                    if isSelected {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 13, weight: .bold))
                                            Text("当前主题")
                                                .font(TvFont.badge)
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.black.opacity(0.55))
                                        .clipShape(Capsule())
                                        .padding(10)
                                    }
                                }

                                HStack {
                                    Circle()
                                        .fill(preset.orbPrimary)
                                        .frame(width: 12, height: 12)
                                    Circle()
                                        .fill(preset.orbSecondary)
                                        .frame(width: 12, height: 12)
                                    Text(preset.name)
                                        .font(TvFont.cardTitle)
                                        .foregroundColor(.white)
                                    Spacer()
                                }

                                Text(preset.subtitle)
                                    .font(TvFont.caption)
                                    .foregroundColor(TvTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            .padding(16)
                        }
                        .buttonStyle(TvTileButtonStyle(active: isSelected, cornerRadius: 18, preserveColors: true))
                    }
                }
            }

            settingsCard {
                Text("柔光氛围浓度与动态联动")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)

                HStack(spacing: 16) {
                    Text("柔光浓度")
                        .font(TvFont.body)
                        .foregroundColor(TvTheme.secondaryText)
                        .frame(width: 110, alignment: .leading)

                    ForEach([("soft", "柔和微光"), ("standard", "标准柔光"), ("vivid", "浓郁流光")], id: \.0) { item in
                        Button(item.1) {
                            appModel.updatePlaybackPreferences { $0.ambientIntensity = item.0 }
                        }
                        .buttonStyle(TvPillButtonStyle(active: appModel.preferences.ambientIntensity == item.0))
                    }

                    Spacer()

                    TvToggleChip(
                        "海报色彩氛围联动",
                        isOn: Binding(
                            get: { appModel.preferences.ambientPosterSync },
                            set: { val in appModel.updatePlaybackPreferences { $0.ambientPosterSync = val } }
                        )
                    )
                }
            }
        }
    }

    // MARK: - 1. LAN QR Push & Manual URL Input

    private var lanQrAndManualUrlSection: some View {
        settingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("订阅配置导入（推荐手机扫码快传）")
                        .font(TvFont.sectionTitle)
                        .foregroundColor(.white)
                    Text("支持一键推送多仓、TVBox JSON、M3U/TXT 直播列表及 marco-movie-backup.json")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }
                Spacer()
                Button {
                    appModel.openLanQrModal()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("手机扫码推送配置")
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
            }

            HStack(spacing: 14) {
                TvGlassInputField(
                    title: "导入订阅或多仓地址",
                    placeholder: "粘贴 HTTP(S) 订阅或多仓地址",
                    text: $manualSubUrl,
                    systemImage: "link"
                )

                TvGlassInputField(
                    title: "订阅备注名称",
                    placeholder: "备注名（可选）",
                    text: $manualSubName,
                    systemImage: "tag"
                )
                .frame(width: 260)

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
                        Text("导入订阅")
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
                .disabled(manualSubUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingUrl)
            }
        }
    }

    // MARK: - 1B. 4K Netdisk Accounts & Multi-Worker Range Proxy

    private var netdiskAndRangeProxySection: some View {
        let authedCount = appModel.loggedInNetdiskDrives.count
        return settingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("4K 网盘账号与多线程加速")
                        .font(TvFont.sectionTitle)
                        .foregroundColor(.white)
                    Text("支持我的夸父、我的优汐、我的嘟嘟、我的阿狸扫码免输授权，已登录 \(authedCount) / 4 个网盘")
                        .font(TvFont.caption)
                        .foregroundColor(authedCount > 0 ? .green : TvTheme.secondaryText)
                }
                Spacer()
                Button {
                    appModel.openNetdiskSheet()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                        Text("管理 4K 网盘扫码授权")
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(NetdiskDriveInfo.allDrives) { drive in
                    let isLogged = appModel.loggedInNetdiskDrives.contains(drive.key)
                    Button {
                        appModel.openNetdiskSheet(preferredDriveKey: drive.key)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(isLogged ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(drive.tvName)
                                    .font(TvFont.cardTitle)
                                Spacer()
                            }
                            Text(isLogged ? "● 已授权 4K 原画" : "点击扫码登录")
                                .font(TvFont.caption)
                                .foregroundColor(isLogged ? .green : TvTheme.secondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(TvTileButtonStyle(active: isLogged, cornerRadius: 14, preserveColors: true))
                }
            }

            Divider().background(TvTheme.glassStroke)

            HStack(spacing: 14) {
                Text("默认网盘画质")
                    .font(TvFont.body)
                    .foregroundColor(TvTheme.secondaryText)
                    .frame(width: 120, alignment: .leading)

                ForEach([("auto", "自动优选"), ("4k_hdr", "4K 原画 HDR"), ("1080p", "1080P 流畅")], id: \.0) { item in
                    Button(item.1) {
                        appModel.updatePlaybackPreferences { $0.netdiskQuality = item.0 }
                    }
                    .buttonStyle(TvPillButtonStyle(active: appModel.preferences.netdiskQuality == item.0, compact: true))
                }
                Spacer()
            }

            HStack(spacing: 14) {
                Text("流媒体加速")
                    .font(TvFont.body)
                    .foregroundColor(TvTheme.secondaryText)
                    .frame(width: 120, alignment: .leading)

                ForEach([("range_proxy", "6 线程分片加速（24 MiB 内存池）"), ("avkit", "AVKit 原生直连")], id: \.0) { item in
                    Button(item.1) {
                        appModel.updatePlaybackPreferences { $0.playerKernel = item.0 }
                    }
                    .buttonStyle(TvPillButtonStyle(active: appModel.preferences.playerKernel == item.0, compact: true))
                }
                Spacer()
            }
        }
    }

    // MARK: - 2. Multi-Depot & Site Capability Status

    private var multiDepotAndSitesSection: some View {
        settingsCard {
            HStack {
                Text("已导入订阅与片源兼容状态")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)
                Spacer()
                Text("可用 \(appModel.config.publicAvailableSites.count) / 共 \(appModel.config.sites.filter { !$0.isEffectivelyPrivate }.count)")
                    .font(TvFont.buttonSmall)
                    .foregroundColor(TvTheme.accent)
            }

            if appModel.subscriptions.isEmpty {
                Text("暂未导入订阅链接，点击上方「手机扫码推送配置」即可快速添加。")
                    .font(TvFont.caption)
                    .foregroundColor(TvTheme.mutedText)
            } else {
                ForEach(appModel.subscriptions) { sub in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(sub.name)
                                    .font(TvFont.cardTitle)
                                    .foregroundColor(.white)
                                if sub.isEffectivelyPrivate {
                                    Text("私密")
                                        .font(TvFont.badge)
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(TvTheme.gold)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(sub.url.isEmpty ? "局域网文本推送" : sub.url)
                                .font(TvFont.caption)
                                .foregroundColor(TvTheme.mutedText)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("移除") {
                            appModel.storage.removeSubscription(id: sub.id)
                            appModel.reloadLocalState()
                        }
                        .buttonStyle(TvPillButtonStyle(compact: true, destructive: true))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(TvTheme.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if !appModel.config.publicDepots.isEmpty {
                Button("打开多仓与片源切换面板（共 \(appModel.config.publicDepots.count) 个仓库）") {
                    appModel.showSiteSwitcherSheet = true
                }
                .buttonStyle(TvPillButtonStyle())
            }

            if !appModel.config.unsupportedSites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已自动置灰的受限片源（共 \(appModel.config.unsupportedSites.count) 个）")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)

                    ForEach(appModel.config.unsupportedSites.prefix(6)) { site in
                        HStack {
                            Text(site.name)
                                .font(TvFont.caption)
                                .foregroundColor(TvTheme.secondaryText)
                            Spacer()
                            Text(site.capabilityStatus)
                                .font(TvFont.badge)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.22))
                                .clipShape(Capsule())
                            Text(site.unsupportedReason)
                                .font(TvFont.caption)
                                .foregroundColor(TvTheme.mutedText)
                        }
                    }
                }
                .padding(14)
                .background(TvTheme.background.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - 3. WebDAV Cloud Sync

    private var webdavCloudSyncSection: some View {
        settingsCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WebDAV 云端双向同步（坚果云 / NAS / Alist）")
                        .font(TvFont.sectionTitle)
                        .foregroundColor(.white)
                    Text("与 Android、iOS、macOS、Windows、鸿蒙共享同一加密与 3-Way 合并同步契约")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                }
                Spacer()
                if !appModel.webdavConfig.lastSyncStatus.isEmpty {
                    Text(appModel.webdavConfig.lastSyncStatus)
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.accent)
                }
            }

            HStack(spacing: 14) {
                TvGlassInputField(
                    title: "WebDAV 服务器地址",
                    placeholder: "WebDAV 地址（如 dav.jianguoyun.com）",
                    text: $appModel.webdavConfig.url,
                    systemImage: "globe"
                )

                TvGlassInputField(
                    title: "WebDAV 账号",
                    placeholder: "账号",
                    text: $appModel.webdavConfig.username,
                    systemImage: "person"
                )
                .frame(width: 245)

                TvGlassInputField(
                    title: "WebDAV 应用密码",
                    placeholder: "应用密码",
                    text: $appModel.webdavConfig.password,
                    systemImage: "key.fill",
                    isSecure: true
                )
                .frame(width: 245)
            }

            HStack(spacing: 12) {
                TvToggleChip("启动时自动同步", isOn: $appModel.webdavConfig.autoSync)
                TvToggleChip("同步公开订阅源", isOn: $appModel.webdavConfig.syncSubscriptions)
                TvToggleChip("同步观看历史与收藏", isOn: $appModel.webdavConfig.syncHistory)

                Spacer()

                Button {
                    Task { await appModel.triggerManualWebDavSync() }
                } label: {
                    if appModel.isSyncingWebDav {
                        ProgressView()
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            Text("保存并立即同步")
                        }
                    }
                }
                .buttonStyle(TvPillButtonStyle(prominent: true))
                .disabled(appModel.isSyncingWebDav)
            }
        }
    }

    // MARK: - 4. Playback Preferences

    private var playbackPreferencesSection: some View {
        settingsCard {
            Text("播放与片头片尾跳过偏好")
                .font(TvFont.sectionTitle)
                .foregroundColor(.white)

            HStack(spacing: 14) {
                Text("跳过片头：\(appModel.preferences.skipIntroSec) 秒")
                    .font(TvFont.body)
                    .foregroundColor(.white)
                    .frame(width: 175, alignment: .leading)

                Button("-15 秒") {
                    appModel.updatePlaybackPreferences { $0.skipIntroSec = max(0, $0.skipIntroSec - 15) }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))

                Button("+15 秒") {
                    appModel.updatePlaybackPreferences { $0.skipIntroSec = min(600, $0.skipIntroSec + 15) }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))

                Spacer().frame(width: 28)

                Text("跳过片尾：\(appModel.preferences.skipOutroSec) 秒")
                    .font(TvFont.body)
                    .foregroundColor(.white)
                    .frame(width: 175, alignment: .leading)

                Button("-15 秒") {
                    appModel.updatePlaybackPreferences { $0.skipOutroSec = max(0, $0.skipOutroSec - 15) }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))

                Button("+15 秒") {
                    appModel.updatePlaybackPreferences { $0.skipOutroSec = min(600, $0.skipOutroSec + 15) }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))

                Spacer()
            }

            HStack(spacing: 12) {
                Text("默认倍速")
                    .font(TvFont.body)
                    .foregroundColor(TvTheme.secondaryText)
                    .frame(width: 100, alignment: .leading)

                ForEach(speedChoices, id: \.self) { sp in
                    Button("\(String(format: "%.2gx", sp))") {
                        appModel.updatePlaybackPreferences { $0.playSpeed = sp }
                    }
                    .buttonStyle(TvPillButtonStyle(active: appModel.preferences.playSpeed == sp, compact: true))
                }

                Spacer()

                TvToggleChip(
                    "自动连播下一集",
                    isOn: Binding(
                        get: { appModel.preferences.autoNext },
                        set: { val in appModel.updatePlaybackPreferences { $0.autoNext = val } }
                    )
                )
            }
        }
    }

    // MARK: - 5. Backup Preview & Factory Reset

    private var backupAndResetSection: some View {
        settingsCard {
            Text("备份导出与存储维护")
                .font(TvFont.sectionTitle)
                .foregroundColor(.white)

            Text("采用 tvOS 合规的 Keychain 压缩锚点 + Caches 工作文件双层架构，即使系统空间紧张回收缓存也可自动自愈恢复，网盘敏感凭据绝不写入导出备份。")
                .font(TvFont.body)
                .foregroundColor(TvTheme.secondaryText)
                .lineSpacing(4)

            HStack(spacing: 16) {
                Button {
                    exportedBackupPreview = (try? appModel.storage.exportBackupJson()) ?? "{}"
                    showBackupPreviewSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("预览备份 JSON")
                    }
                }
                .buttonStyle(TvPillButtonStyle())

                Button {
                    showResetConfirmation = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.slash")
                        Text("清空本地与钥匙串全部数据")
                    }
                }
                .buttonStyle(TvPillButtonStyle(destructive: true))

                Spacer()
            }
        }
    }
}

private struct BackupPreviewModal: View {
    let jsonText: String
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("跨端备份 JSON 预览（schema: marco-movie-backup）")
                    .font(TvFont.sectionTitle)
                    .foregroundColor(.white)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(TvPillButtonStyle(prominent: true, compact: true))
            }
            ScrollView {
                Text(jsonText)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(TvTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .background(TvTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .tvExitHandler { dismiss() }
    }
}

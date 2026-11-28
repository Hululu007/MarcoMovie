// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MarcoTVCore
import SwiftUI

/// Structured 10-foot episode card content shared between the immersive detail quick-rail
/// and the dedicated Apple TV episode selection grid. Automatically adapts typography,
/// badges, and progress bar contrast when focused via `tvTileFocused`.
public struct TvEpisodeCardContent: View {
    @Environment(\.tvTileFocused) private var isFocused

    public let episodeNumber: Int
    public let title: String
    public let badgeLabel: String?
    public let subtitle: String?
    public let isHighlighted: Bool
    public let isNetdisk4K: Bool
    public let progressFraction: Double
    public let cardHeight: CGFloat

    public init(
        episodeNumber: Int,
        title: String,
        badgeLabel: String? = nil,
        subtitle: String? = nil,
        isHighlighted: Bool = false,
        isNetdisk4K: Bool = false,
        progressFraction: Double = 0,
        cardHeight: CGFloat = 104
    ) {
        self.episodeNumber = episodeNumber
        self.title = title
        self.badgeLabel = badgeLabel
        self.subtitle = subtitle
        self.isHighlighted = isHighlighted
        self.isNetdisk4K = isNetdisk4K
        self.progressFraction = progressFraction
        self.cardHeight = cardHeight
    }

    private var indexBadgeText: String {
        String(format: "EP %02d", episodeNumber)
    }

    private var primaryColor: Color {
        isFocused ? TvTheme.darkInk : .white
    }

    private var secondaryColor: Color {
        isFocused ? Color(red: 0.24, green: 0.30, blue: 0.38) : TvTheme.secondaryText
    }

    private var mutedColor: Color {
        isFocused ? Color(red: 0.35, green: 0.42, blue: 0.52) : TvTheme.mutedText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if isHighlighted {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isFocused ? TvTheme.accent : Color(red: 0.56, green: 0.80, blue: 1.0))
                }

                Text(indexBadgeText)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(secondaryColor)

                Spacer(minLength: 6)

                if let badge = badgeLabel, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isFocused ? .white : Color(red: 0.84, green: 0.93, blue: 1.0))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                isFocused
                                    ? TvTheme.accent
                                    : TvTheme.accent.opacity(0.42)
                            )
                        )
                } else if isNetdisk4K {
                    Text("4K")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(isFocused ? Color(red: 0.72, green: 0.42, blue: 0.0) : TvTheme.gold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                isFocused
                                    ? Color.orange.opacity(0.16)
                                    : Color.orange.opacity(0.24)
                            )
                        )
                }
            }

            Text(title)
                .font(TvFont.cardTitle)
                .foregroundColor(primaryColor)
                .lineLimit(1)

            if progressFraction > 0.01 {
                GeometryReader { barGeo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isFocused ? Color.black.opacity(0.14) : Color.white.opacity(0.20))
                        Capsule()
                            .fill(TvTheme.accent)
                            .frame(width: max(6, barGeo.size.width * min(max(progressFraction, 0), 1)))
                    }
                }
                .frame(height: 4)
            } else if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(mutedColor)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
    }
}

/// Dedicated full-screen immersive Episode Selection page (`选集页`) for Apple TV.
/// Designed for effortless 10-foot Siri Remote browsing with adaptive 4/5-column grid density,
/// 20-episode single-screen range tabs, inline line switcher, and quick-jump to watched/playing episode.
public struct EpisodeSelectionView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    public let site: CmsSite
    public let video: CmsVideo
    @Binding public var selectedLineIndex: Int
    @Binding public var descending: Bool
    public let activePlayingLineIndex: Int?
    public let activePlayingEpisodeIndex: Int?
    public let onSelectEpisode: (_ lineIndex: Int, _ episodeIndex: Int, _ resumeMs: Int) -> Void

    private static let episodesPerPage = EpisodePaginationPlanner.episodesPerPage

    @State private var selectedPageIndex: Int = 0
    @State private var pendingJumpTarget: TargetEpisodeLocation?
    @State private var lastFocusedEpisodeOffset: Int?
    @State private var showNetdiskSheet = false
    @FocusState private var focusedEpisodeOffset: Int?

    public init(
        site: CmsSite,
        video: CmsVideo,
        selectedLineIndex: Binding<Int>,
        descending: Binding<Bool>,
        activePlayingLineIndex: Int? = nil,
        activePlayingEpisodeIndex: Int? = nil,
        onSelectEpisode: @escaping (_ lineIndex: Int, _ episodeIndex: Int, _ resumeMs: Int) -> Void
    ) {
        self.site = site
        self.video = video
        self._selectedLineIndex = selectedLineIndex
        self._descending = descending
        self.activePlayingLineIndex = activePlayingLineIndex
        self.activePlayingEpisodeIndex = activePlayingEpisodeIndex
        self.onSelectEpisode = onSelectEpisode
    }

    private var savedHistory: WatchHistoryItem? {
        MediaEntryResolver.matchingHistory(
            for: site,
            videoId: video.id,
            in: appModel.watchHistory,
            config: appModel.config
        )
    }

    private var lineEpisodeCounts: [Int] {
        video.lines.map { $0.episodes.count }
    }

    private var safeLineIndex: Int {
        EpisodePaginationPlanner.clampedLineIndex(selectedLineIndex, lineCount: video.lines.count)
    }

    private var currentLine: CmsLine? {
        guard video.lines.indices.contains(safeLineIndex) else { return nil }
        return video.lines[safeLineIndex]
    }

    private var orderedEpisodes: [(offset: Int, element: CmsEpisode)] {
        guard let eps = currentLine?.episodes else { return [] }
        return EpisodePaginationPlanner.orderedOffsets(episodeCount: eps.count, descending: descending)
            .map { (offset: $0, element: eps[$0]) }
    }

    private var pageCount: Int {
        EpisodePaginationPlanner.pageCount(episodeCount: currentLine?.episodes.count ?? 0)
    }

    private var safePageIndex: Int {
        EpisodePaginationPlanner.clampedPageIndex(selectedPageIndex, episodeCount: currentLine?.episodes.count ?? 0)
    }

    private var visibleSlice: [(offset: Int, element: CmsEpisode)] {
        guard let eps = currentLine?.episodes else { return [] }
        return EpisodePaginationPlanner.sliceOffsets(
            episodeCount: eps.count,
            descending: descending,
            pageIndex: safePageIndex
        ).map { (offset: $0, element: eps[$0]) }
    }

    private var targetJumpLocation: (lineIndex: Int, episodeIndex: Int, label: String)? {
        if let pLine = activePlayingLineIndex,
           let pEp = activePlayingEpisodeIndex,
           video.lines.indices.contains(pLine),
           video.lines[pLine].episodes.indices.contains(pEp)
        {
            return (pLine, pEp, "定位当前播放")
        }
        if let hist = savedHistory,
           let hLine = video.lines.firstIndex(where: { $0.name == hist.line }),
           video.lines[hLine].episodes.indices.contains(hist.index)
        {
            return (hLine, hist.index, "定位上次观看")
        }
        return nil
    }

    private var targetLocationModel: TargetEpisodeLocation? {
        guard let target = targetJumpLocation else { return nil }
        return TargetEpisodeLocation(lineIndex: target.lineIndex, episodeIndex: target.episodeIndex)
    }

    private var isTargetVisibleOnCurrentPage: Bool {
        guard let target = targetJumpLocation else { return true }
        guard target.lineIndex == safeLineIndex else { return false }
        return visibleSlice.contains { $0.offset == target.episodeIndex }
    }

    private var adaptiveColumnCount: Int {
        let slice = visibleSlice
        let maxLen = slice.map { $0.element.name.trimmingCharacters(in: .whitespacesAndNewlines).count }.max() ?? 4
        if slice.count <= 8 || maxLen >= 10 {
            return 4
        }
        return 5
    }

    private var hasAnyNetdiskLine: Bool {
        video.lines.contains { $0.isNetdiskLine }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Spacer(minLength: 24)

            // Bottom-anchored spacious frosted-glass episode panel (hugs content cleanly
            // so the upper atmospheric artwork breathes instead of leaving dead dark space)
            VStack(alignment: .leading, spacing: 18) {
                playLineRow

                if let driveKey = currentLine?.netdiskDriveKey,
                   !appModel.loggedInNetdiskDrives.contains(driveKey),
                   let driveInfo = NetdiskDriveInfo.info(for: driveKey)
                {
                    netdiskNoticeBar(driveKey: driveKey, driveInfo: driveInfo)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.11))
                    .frame(height: 1)

                rangePaginationToolbar

                episodeGridSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(TvTheme.glassStroke, lineWidth: 1.2)
            )
            .shadow(color: .black.opacity(0.48), radius: 30, y: 14)
        }
        .padding(.horizontal, 64)
        .padding(.top, 40)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            TvImmersiveArtworkBackdrop(
                posterUrl: video.poster,
                headers: site.headers,
                themeId: appModel.preferences.ambientTheme,
                intensity: appModel.preferences.ambientIntensity,
                softened: true
            )
        )
        #if os(tvOS)
        .fullScreenCover(isPresented: $showNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        #else
        .sheet(isPresented: $showNetdiskSheet) {
            NetdiskAccountSheetView()
                .environmentObject(appModel)
        }
        #endif
        .onAppear {
            syncPageAndFocusToTarget()
        }
        .onChange(of: focusedEpisodeOffset) { newOffset in
            if let newOffset = newOffset {
                lastFocusedEpisodeOffset = newOffset
            }
        }
        .onChange(of: selectedLineIndex) { newLine in
            let reconciled = EpisodePaginationPlanner.reconcileLineChange(
                newLineIndex: newLine,
                pendingJumpTarget: pendingJumpTarget,
                target: targetLocationModel,
                lineEpisodeCounts: lineEpisodeCounts,
                descending: descending
            )
            if reconciled.consumedPendingJump {
                pendingJumpTarget = nil
            }
            selectedPageIndex = reconciled.state.pageIndex
            applyFocusTarget(reconciled.state.focusedEpisodeOffset)
        }
        .tvExitHandler {
            dismiss()
        }
    }

    private var headerBar: some View {
        let total = currentLine?.episodes.count ?? 0
        return HStack(alignment: .center, spacing: 18) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                    Text("返回")
                }
            }
            .buttonStyle(TvPillButtonStyle(compact: true))

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 1.5, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(TvFont.pageTitle)
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("选集 · 共 \(total) 集")
                        .font(TvFont.caption)
                        .foregroundColor(TvTheme.secondaryText)
                    if let lineName = currentLine?.name, !lineName.isEmpty {
                        Text("·")
                            .foregroundColor(TvTheme.mutedText)
                        Text(lineName)
                            .font(TvFont.caption)
                            .foregroundColor(Color(red: 0.72, green: 0.86, blue: 1.0))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 16)

            if let target = targetJumpLocation, !isTargetVisibleOnCurrentPage {
                Button {
                    jumpToTarget(lineIndex: target.lineIndex, episodeIndex: target.episodeIndex)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .font(.system(size: 14, weight: .semibold))
                        Text(target.label)
                    }
                }
                .buttonStyle(TvPillButtonStyle(active: true, compact: true))
            }

            Button {
                let currentState = EpisodePageState(
                    lineIndex: safeLineIndex,
                    pageIndex: safePageIndex,
                    descending: descending,
                    focusedEpisodeOffset: focusedEpisodeOffset ?? lastFocusedEpisodeOffset
                )
                let nextState = EpisodePaginationPlanner.toggleOrder(
                    currentState: currentState,
                    anchorEpisodeOffset: focusedEpisodeOffset ?? lastFocusedEpisodeOffset,
                    target: targetLocationModel,
                    lineEpisodeCounts: lineEpisodeCounts
                )
                descending = nextState.descending
                appModel.updatePlaybackPreferences { $0.episodesDescending = nextState.descending }
                selectedPageIndex = nextState.pageIndex
                applyFocusTarget(nextState.focusedEpisodeOffset)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                    Text(descending ? "倒序" : "正序")
                }
            }
            .buttonStyle(TvPillButtonStyle(compact: true))

            if hasAnyNetdiskLine {
                Button {
                    if let key = currentLine?.netdiskDriveKey {
                        appModel.selectedNetdiskDriveKey = key
                    }
                    showNetdiskSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 14, weight: .semibold))
                        Text("云盘扫码")
                    }
                }
                .buttonStyle(TvPillButtonStyle(compact: true))
            }

            MarcoBrandLogo(iconSize: 34, fontSize: 20)
        }
    }

    private var playLineRow: some View {
        HStack(spacing: 16) {
            Text("播放线路")
                .font(TvFont.cardTitle)
                .foregroundColor(TvTheme.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(video.lines.enumerated()), id: \.offset) { idx, line in
                        let isActive = safeLineIndex == idx
                        Button {
                            selectLine(idx)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(line.name) (\(line.episodes.count))")
                                if line.isNetdiskLine {
                                    Text("4K 云盘")
                                        .font(TvFont.badge)
                                        .foregroundColor(TvTheme.gold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(red: 0.14, green: 0.10, blue: 0.04).opacity(0.82))
                                        .overlay(Capsule().strokeBorder(TvTheme.gold.opacity(0.65), lineWidth: 0.8))
                                        .clipShape(Capsule())
                                } else if line.isM3u8Preferred {
                                    Text("HLS")
                                        .font(TvFont.badge)
                                        .foregroundColor(Color(red: 0.56, green: 0.96, blue: 0.72))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(red: 0.04, green: 0.18, blue: 0.10).opacity(0.82))
                                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.60), lineWidth: 0.8))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .buttonStyle(TvPillButtonStyle(active: isActive, compact: true))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
    }

    private func netdiskNoticeBar(driveKey: String, driveInfo: NetdiskDriveInfo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(TvTheme.gold)
            Text("当前线路需登录「\(driveInfo.tvName)（\(driveInfo.providerName)）」以启用 6 线程 4K 原画直连")
                .font(TvFont.caption)
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("立即扫码登录") {
                appModel.selectedNetdiskDriveKey = driveKey
                showNetdiskSheet = true
            }
            .buttonStyle(TvPillButtonStyle(prominent: true, compact: true))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.36), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var rangePaginationToolbar: some View {
        let total = orderedEpisodes.count
        return HStack(spacing: 14) {
            if pageCount > 1 {
                Text("分组")
                    .font(TvFont.cardTitle)
                    .foregroundColor(TvTheme.secondaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<pageCount, id: \.self) { pIdx in
                            let label = pageRangeLabel(for: pIdx, total: total)
                            Button(label) {
                                let nextState = EpisodePaginationPlanner.selectPage(
                                    pageIndex: pIdx,
                                    lineIndex: safeLineIndex,
                                    descending: descending,
                                    target: targetLocationModel,
                                    lineEpisodeCounts: lineEpisodeCounts
                                )
                                selectedPageIndex = nextState.pageIndex
                                applyFocusTarget(nextState.focusedEpisodeOffset)
                            }
                            .buttonStyle(TvPillButtonStyle(active: safePageIndex == pIdx, compact: true))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            } else {
                Text("全部剧集（共 \(total) 集）")
                    .font(TvFont.cardTitle)
                    .foregroundColor(.white)
                Spacer()
            }

            Text("方向键选集 · 按确认键立即播放")
                .font(TvFont.caption)
                .foregroundColor(TvTheme.mutedText)
                .lineLimit(1)
        }
    }

    private var episodeGridSection: some View {
        let slice = visibleSlice
        let colCount = adaptiveColumnCount
        let spacing: CGFloat = colCount == 4 ? 18 : 16
        let tileHeight: CGFloat = colCount == 4 ? 108 : 100
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: colCount)
        let isNetdisk = currentLine?.isNetdiskLine ?? false
        let rowCount = max(1, (slice.count + colCount - 1) / colCount)
        let naturalHeight = CGFloat(rowCount) * tileHeight + CGFloat(max(0, rowCount - 1)) * spacing + 28
        let cappedHeight = min(naturalHeight, 520)

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: spacing) {
                ForEach(slice, id: \.offset) { item in
                    let isCurrentlyPlaying = activePlayingLineIndex == safeLineIndex
                        && activePlayingEpisodeIndex == item.offset
                    let isLastWatched = savedHistory?.index == item.offset
                        && savedHistory?.line == currentLine?.name
                    let highlighted = isCurrentlyPlaying || isLastWatched
                    let progress = isLastWatched ? (savedHistory?.progressFraction ?? 0) : 0
                    let badge: String? = {
                        if isCurrentlyPlaying { return "当前播放" }
                        if isLastWatched {
                            if progress > 0.01 {
                                return "上次观看 · \(Int(progress * 100))%"
                            }
                            return "上次观看"
                        }
                        return nil
                    }()

                    Button {
                        let seek = (!isCurrentlyPlaying && isLastWatched) ? (savedHistory?.resumePosition ?? 0) : 0
                        onSelectEpisode(safeLineIndex, item.offset, seek)
                        dismiss()
                    } label: {
                        TvEpisodeCardContent(
                            episodeNumber: item.offset + 1,
                            title: item.element.name,
                            badgeLabel: badge,
                            subtitle: isCurrentlyPlaying ? "正在播放当前分集" : nil,
                            isHighlighted: highlighted,
                            isNetdisk4K: isNetdisk,
                            progressFraction: progress,
                            cardHeight: tileHeight
                        )
                    }
                    .buttonStyle(TvEpisodeTileButtonStyle(active: highlighted, cornerRadius: 18))
                    .focused($focusedEpisodeOffset, equals: item.offset)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .frame(height: cappedHeight)
    }

    private func pageRangeLabel(for pageIndex: Int, total: Int) -> String {
        EpisodePaginationPlanner.pageRangeLabel(
            pageIndex: pageIndex,
            episodeCount: total,
            descending: descending
        )
    }

    private func syncPageAndFocusToTarget() {
        let initial = EpisodePaginationPlanner.initialState(
            selectedLineIndex: safeLineIndex,
            descending: descending,
            target: targetLocationModel,
            lineEpisodeCounts: lineEpisodeCounts
        )
        selectedPageIndex = initial.pageIndex
        applyFocusTarget(initial.focusedEpisodeOffset)
    }

    private func selectLine(_ newLineIndex: Int) {
        pendingJumpTarget = nil
        if newLineIndex == selectedLineIndex {
            let state = EpisodePaginationPlanner.initialState(
                selectedLineIndex: newLineIndex,
                descending: descending,
                target: targetLocationModel,
                lineEpisodeCounts: lineEpisodeCounts
            )
            selectedPageIndex = state.pageIndex
            applyFocusTarget(state.focusedEpisodeOffset)
        } else {
            selectedLineIndex = newLineIndex
        }
    }

    private func jumpToTarget(lineIndex: Int, episodeIndex: Int) {
        let target = TargetEpisodeLocation(lineIndex: lineIndex, episodeIndex: episodeIndex)
        let jumped = EpisodePaginationPlanner.jumpToTarget(
            target: target,
            lineEpisodeCounts: lineEpisodeCounts,
            descending: descending
        )
        if selectedLineIndex != jumped.lineIndex {
            // Preserve the jumped page and focus target when SwiftUI fires `.onChange(of: selectedLineIndex)`.
            pendingJumpTarget = target
            selectedLineIndex = jumped.lineIndex
        } else {
            pendingJumpTarget = nil
        }
        selectedPageIndex = jumped.pageIndex
        applyFocusTarget(jumped.focusedEpisodeOffset)
    }

    private func applyFocusTarget(_ offset: Int?) {
        if let offset = offset {
            lastFocusedEpisodeOffset = offset
        }
        focusedEpisodeOffset = offset
        guard let targetOffset = offset else { return }
        DispatchQueue.main.async {
            if self.visibleSlice.contains(where: { $0.offset == targetOffset }) {
                self.focusedEpisodeOffset = targetOffset
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

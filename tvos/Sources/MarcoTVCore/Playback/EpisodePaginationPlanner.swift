// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Target episode identity used by `EpisodeSelectionView` quick-jump and pagination logic.
public struct TargetEpisodeLocation: Equatable, Hashable, Sendable {
    public let lineIndex: Int
    public let episodeIndex: Int

    public init(lineIndex: Int, episodeIndex: Int) {
        self.lineIndex = lineIndex
        self.episodeIndex = episodeIndex
    }
}

/// Deterministic UI pagination & focus state for the 20-episode-per-page Apple TV episode picker.
public struct EpisodePageState: Equatable, Sendable {
    public var lineIndex: Int
    public var pageIndex: Int
    public var descending: Bool
    public var focusedEpisodeOffset: Int?

    public init(
        lineIndex: Int,
        pageIndex: Int,
        descending: Bool,
        focusedEpisodeOffset: Int?
    ) {
        self.lineIndex = lineIndex
        self.pageIndex = pageIndex
        self.descending = descending
        self.focusedEpisodeOffset = focusedEpisodeOffset
    }
}

/// Pure 20-episode-per-page pagination, cross-line jump, and order-preserving focus planner.
public enum EpisodePaginationPlanner {
    public static let episodesPerPage = 20

    public static func clampedLineIndex(_ lineIndex: Int, lineCount: Int) -> Int {
        guard lineCount > 0 else { return 0 }
        return min(max(lineIndex, 0), lineCount - 1)
    }

    public static func orderedOffsets(episodeCount: Int, descending: Bool) -> [Int] {
        guard episodeCount > 0 else { return [] }
        let asc = Array(0..<episodeCount)
        return descending ? asc.reversed() : asc
    }

    public static func pageCount(episodeCount: Int) -> Int {
        guard episodeCount > 0 else { return 1 }
        return max(1, (episodeCount + episodesPerPage - 1) / episodesPerPage)
    }

    public static func clampedPageIndex(_ pageIndex: Int, episodeCount: Int) -> Int {
        let maxIdx = max(0, pageCount(episodeCount: episodeCount) - 1)
        return min(max(pageIndex, 0), maxIdx)
    }

    public static func pageIndex(
        forEpisodeOffset offset: Int,
        episodeCount: Int,
        descending: Bool
    ) -> Int? {
        guard offset >= 0, offset < episodeCount else { return nil }
        let orderedPos = descending ? (episodeCount - 1 - offset) : offset
        return orderedPos / episodesPerPage
    }

    public static func sliceOffsets(
        episodeCount: Int,
        descending: Bool,
        pageIndex: Int
    ) -> [Int] {
        let ordered = orderedOffsets(episodeCount: episodeCount, descending: descending)
        let safePage = clampedPageIndex(pageIndex, episodeCount: episodeCount)
        let start = min(safePage * episodesPerPage, ordered.count)
        let end = min(start + episodesPerPage, ordered.count)
        return Array(ordered[start..<end])
    }

    public static func pageRangeLabel(
        pageIndex: Int,
        episodeCount: Int,
        descending: Bool
    ) -> String {
        let slice = sliceOffsets(episodeCount: episodeCount, descending: descending, pageIndex: pageIndex)
        guard let first = slice.first, let last = slice.last else {
            let start = pageIndex * episodesPerPage + 1
            let end = min(episodeCount, start + episodesPerPage - 1)
            return "\(start)-\(max(start, end))"
        }
        return "\(first + 1)-\(last + 1)"
    }

    public static func initialState(
        selectedLineIndex: Int,
        descending: Bool,
        target: TargetEpisodeLocation?,
        lineEpisodeCounts: [Int]
    ) -> EpisodePageState {
        let safeLine = clampedLineIndex(selectedLineIndex, lineCount: lineEpisodeCounts.count)
        let count = lineEpisodeCounts.indices.contains(safeLine) ? lineEpisodeCounts[safeLine] : 0
        if let target = target,
           target.lineIndex == safeLine,
           let page = pageIndex(forEpisodeOffset: target.episodeIndex, episodeCount: count, descending: descending)
        {
            return EpisodePageState(
                lineIndex: safeLine,
                pageIndex: page,
                descending: descending,
                focusedEpisodeOffset: target.episodeIndex
            )
        }
        let firstOffset = sliceOffsets(episodeCount: count, descending: descending, pageIndex: 0).first
        return EpisodePageState(
            lineIndex: safeLine,
            pageIndex: 0,
            descending: descending,
            focusedEpisodeOffset: firstOffset
        )
    }

    /// Jumps from any line (e.g. Line B) directly to `target` (e.g. Line A EP 45),
    /// landing on the exact 20-episode page in ascending or descending order and keeping focus on that episode.
    public static func jumpToTarget(
        target: TargetEpisodeLocation,
        lineEpisodeCounts: [Int],
        descending: Bool
    ) -> EpisodePageState {
        let safeLine = clampedLineIndex(target.lineIndex, lineCount: lineEpisodeCounts.count)
        let count = lineEpisodeCounts.indices.contains(safeLine) ? lineEpisodeCounts[safeLine] : 0
        if let page = pageIndex(forEpisodeOffset: target.episodeIndex, episodeCount: count, descending: descending) {
            return EpisodePageState(
                lineIndex: safeLine,
                pageIndex: page,
                descending: descending,
                focusedEpisodeOffset: target.episodeIndex
            )
        }
        let firstOffset = sliceOffsets(episodeCount: count, descending: descending, pageIndex: 0).first
        return EpisodePageState(
            lineIndex: safeLine,
            pageIndex: 0,
            descending: descending,
            focusedEpisodeOffset: firstOffset
        )
    }

    /// Handles SwiftUI `.onChange(of: selectedLineIndex)` without clobbering an active cross-line jump.
    public static func reconcileLineChange(
        newLineIndex: Int,
        pendingJumpTarget: TargetEpisodeLocation?,
        target: TargetEpisodeLocation?,
        lineEpisodeCounts: [Int],
        descending: Bool
    ) -> (state: EpisodePageState, consumedPendingJump: Bool) {
        let safeLine = clampedLineIndex(newLineIndex, lineCount: lineEpisodeCounts.count)
        if let pending = pendingJumpTarget, pending.lineIndex == safeLine {
            let jumped = jumpToTarget(target: pending, lineEpisodeCounts: lineEpisodeCounts, descending: descending)
            return (jumped, true)
        }
        let resolved = initialState(
            selectedLineIndex: safeLine,
            descending: descending,
            target: target,
            lineEpisodeCounts: lineEpisodeCounts
        )
        return (resolved, false)
    }

    /// Flips ascending/descending order while keeping the anchor (focused/playing/last-watched) episode selected
    /// and switching `pageIndex` to the exact page that contains that same episode in the new sort order.
    public static func toggleOrder(
        currentState: EpisodePageState,
        anchorEpisodeOffset: Int?,
        target: TargetEpisodeLocation?,
        lineEpisodeCounts: [Int]
    ) -> EpisodePageState {
        let newDescending = !currentState.descending
        let safeLine = clampedLineIndex(currentState.lineIndex, lineCount: lineEpisodeCounts.count)
        let count = lineEpisodeCounts.indices.contains(safeLine) ? lineEpisodeCounts[safeLine] : 0

        let candidateAnchor: Int? = {
            if let explicit = anchorEpisodeOffset, explicit >= 0, explicit < count {
                return explicit
            }
            if let focused = currentState.focusedEpisodeOffset, focused >= 0, focused < count {
                return focused
            }
            if let target = target, target.lineIndex == safeLine, target.episodeIndex >= 0, target.episodeIndex < count {
                return target.episodeIndex
            }
            return nil
        }()

        if let anchor = candidateAnchor,
           let page = pageIndex(forEpisodeOffset: anchor, episodeCount: count, descending: newDescending)
        {
            return EpisodePageState(
                lineIndex: safeLine,
                pageIndex: page,
                descending: newDescending,
                focusedEpisodeOffset: anchor
            )
        }

        let firstOffset = sliceOffsets(episodeCount: count, descending: newDescending, pageIndex: 0).first
        return EpisodePageState(
            lineIndex: safeLine,
            pageIndex: 0,
            descending: newDescending,
            focusedEpisodeOffset: firstOffset
        )
    }

    public static func selectPage(
        pageIndex: Int,
        lineIndex: Int,
        descending: Bool,
        target: TargetEpisodeLocation?,
        lineEpisodeCounts: [Int]
    ) -> EpisodePageState {
        let safeLine = clampedLineIndex(lineIndex, lineCount: lineEpisodeCounts.count)
        let count = lineEpisodeCounts.indices.contains(safeLine) ? lineEpisodeCounts[safeLine] : 0
        let safePage = clampedPageIndex(pageIndex, episodeCount: count)
        let slice = sliceOffsets(episodeCount: count, descending: descending, pageIndex: safePage)
        let focusOffset: Int? = {
            if let target = target,
               target.lineIndex == safeLine,
               slice.contains(target.episodeIndex)
            {
                return target.episodeIndex
            }
            return slice.first
        }()
        return EpisodePageState(
            lineIndex: safeLine,
            pageIndex: safePage,
            descending: descending,
            focusedEpisodeOffset: focusOffset
        )
    }
}

/// Pure multi-layer focus restoration planner for Apple TV Back navigation:
/// Player -> EpisodeSelection -> DetailView (original episode/action) -> Discover / Library / Search (original poster).
public enum FocusRestorationPlanner {
    public enum DetailReturnFocus: Equatable, Hashable, Sendable {
        case play
        case allEpisodes
        case quickAllEpisodes
        case episode(lineIndex: Int, episodeIndex: Int)
    }

    public static func resolveAfterEpisodeSelectionDismiss(
        lastFocusBeforeModal: DetailReturnFocus,
        currentLineIndex: Int,
        visibleRailEpisodeOffsets: [Int]
    ) -> DetailReturnFocus {
        if case .episode(let lineIdx, let epIdx) = lastFocusBeforeModal {
            if lineIdx == currentLineIndex && visibleRailEpisodeOffsets.contains(epIdx) {
                return .episode(lineIndex: lineIdx, episodeIndex: epIdx)
            }
            return .allEpisodes
        }
        return lastFocusBeforeModal
    }

    public static func resolveAfterPlayerDismiss(
        lastFocusBeforeModal: DetailReturnFocus,
        lastPlayedLineIndex: Int?,
        lastPlayedEpisodeIndex: Int?,
        savedHistoryLineIndex: Int?,
        savedHistoryEpisodeIndex: Int?,
        currentLineIndex: Int,
        visibleRailEpisodeOffsets: [Int]
    ) -> DetailReturnFocus {
        // Prefer the most recently watched episode (e.g. if user switched episodes inside the player),
        // falling back to the episode card that launched playback, then the button that opened playback.
        if let hLine = savedHistoryLineIndex,
           let hEp = savedHistoryEpisodeIndex,
           hLine == currentLineIndex,
           visibleRailEpisodeOffsets.contains(hEp)
        {
            if case .episode = lastFocusBeforeModal {
                return .episode(lineIndex: hLine, episodeIndex: hEp)
            }
            if lastPlayedEpisodeIndex != nil {
                return .episode(lineIndex: hLine, episodeIndex: hEp)
            }
        }
        if let pLine = lastPlayedLineIndex,
           let pEp = lastPlayedEpisodeIndex,
           pLine == currentLineIndex,
           visibleRailEpisodeOffsets.contains(pEp)
        {
            return .episode(lineIndex: pLine, episodeIndex: pEp)
        }
        return resolveAfterEpisodeSelectionDismiss(
            lastFocusBeforeModal: lastFocusBeforeModal,
            currentLineIndex: currentLineIndex,
            visibleRailEpisodeOffsets: visibleRailEpisodeOffsets
        )
    }

    public static func resolvePosterCardReturn<Key: Hashable>(
        lastOpenedKey: Key?,
        availableKeys: [Key]
    ) -> Key? {
        guard let key = lastOpenedKey else { return nil }
        return availableKeys.contains(key) ? key : nil
    }
}

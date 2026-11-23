// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import Foundation
import XCTest
@testable import MarcoTVCore

final class EpisodePaginationAndFocusTests: XCTestCase {

    // MARK: - Cross-Line Jump (Line B -> Line A EP 45) Ascending & Descending

    func testCrossLineJumpFromLineBToLineAEpisode45AscendingAndDescending() {
        let targetEp45 = TargetEpisodeLocation(lineIndex: 0, episodeIndex: 44) // 1-based EP 45

        // Case 1: Line A has 60 episodes, Line B has 50 episodes
        let counts60 = [60, 50]

        // Ascending: EP 45 (offset 44) MUST land on Page 3 (index 2, range 41-60) with focus on offset 44
        let jumpedAsc = EpisodePaginationPlanner.jumpToTarget(
            target: targetEp45,
            lineEpisodeCounts: counts60,
            descending: false
        )
        XCTAssertEqual(jumpedAsc.lineIndex, 0)
        XCTAssertEqual(jumpedAsc.pageIndex, 2, "Ascending EP 45 must land on Page 3 (0-based index 2)")
        XCTAssertEqual(jumpedAsc.focusedEpisodeOffset, 44)
        XCTAssertEqual(
            EpisodePaginationPlanner.pageRangeLabel(pageIndex: jumpedAsc.pageIndex, episodeCount: 60, descending: false),
            "41-60"
        )
        let ascSlice = EpisodePaginationPlanner.sliceOffsets(episodeCount: 60, descending: false, pageIndex: jumpedAsc.pageIndex)
        XCTAssertEqual(ascSlice.count, 20)
        XCTAssertTrue(ascSlice.contains(44))

        // SwiftUI `.onChange(of: selectedLineIndex)` reconciliation MUST NOT reset Page 3 back to Page 1!
        let reconciledAsc = EpisodePaginationPlanner.reconcileLineChange(
            newLineIndex: 0,
            pendingJumpTarget: targetEp45,
            target: targetEp45,
            lineEpisodeCounts: counts60,
            descending: false
        )
        XCTAssertTrue(reconciledAsc.consumedPendingJump)
        XCTAssertEqual(reconciledAsc.state.pageIndex, 2, "Line change callback must preserve Page 3 during cross-line jump")
        XCTAssertEqual(reconciledAsc.state.focusedEpisodeOffset, 44)

        // Toggle ascending -> descending while anchored on EP 45: MUST stay on EP 45 (offset 44)
        let toggledToDesc = EpisodePaginationPlanner.toggleOrder(
            currentState: jumpedAsc,
            anchorEpisodeOffset: 44,
            target: targetEp45,
            lineEpisodeCounts: counts60
        )
        XCTAssertTrue(toggledToDesc.descending)
        XCTAssertEqual(toggledToDesc.focusedEpisodeOffset, 44, "Toggling to descending must keep EP 45 selected")
        let descSlice60 = EpisodePaginationPlanner.sliceOffsets(episodeCount: 60, descending: true, pageIndex: toggledToDesc.pageIndex)
        XCTAssertTrue(descSlice60.contains(44), "Descending page slice must contain EP 45")
        XCTAssertEqual(
            EpisodePaginationPlanner.pageRangeLabel(pageIndex: toggledToDesc.pageIndex, episodeCount: 60, descending: true),
            "60-41"
        )

        // Toggle back descending -> ascending: returns cleanly to Page 3 (41-60) with EP 45 selected
        let toggledBackAsc = EpisodePaginationPlanner.toggleOrder(
            currentState: toggledToDesc,
            anchorEpisodeOffset: 44,
            target: targetEp45,
            lineEpisodeCounts: counts60
        )
        XCTAssertFalse(toggledBackAsc.descending)
        XCTAssertEqual(toggledBackAsc.pageIndex, 2)
        XCTAssertEqual(toggledBackAsc.focusedEpisodeOffset, 44)

        // Case 2: Line A has 100 episodes -> EP 45 in descending order is at position 55 -> Page 3 (index 2, range 60-41)
        let counts100 = [100, 80]
        let jumpedDesc100 = EpisodePaginationPlanner.jumpToTarget(
            target: targetEp45,
            lineEpisodeCounts: counts100,
            descending: true
        )
        XCTAssertEqual(jumpedDesc100.lineIndex, 0)
        XCTAssertEqual(jumpedDesc100.pageIndex, 2, "In 100-ep descending order, EP 45 (pos 55) must land on Page 3 (60-41), not Page 1")
        XCTAssertEqual(jumpedDesc100.focusedEpisodeOffset, 44)
        let descSlice100 = EpisodePaginationPlanner.sliceOffsets(episodeCount: 100, descending: true, pageIndex: jumpedDesc100.pageIndex)
        XCTAssertEqual(descSlice100.count, 20)
        XCTAssertTrue(descSlice100.contains(44))
        XCTAssertEqual(
            EpisodePaginationPlanner.pageRangeLabel(pageIndex: jumpedDesc100.pageIndex, episodeCount: 100, descending: true),
            "60-41"
        )

        // Reconciliation in descending mode also preserves Page 3 & EP 45
        let reconciledDesc100 = EpisodePaginationPlanner.reconcileLineChange(
            newLineIndex: 0,
            pendingJumpTarget: targetEp45,
            target: targetEp45,
            lineEpisodeCounts: counts100,
            descending: true
        )
        XCTAssertTrue(reconciledDesc100.consumedPendingJump)
        XCTAssertEqual(reconciledDesc100.state.pageIndex, 2)
        XCTAssertEqual(reconciledDesc100.state.focusedEpisodeOffset, 44)
    }

    func testManualLineSwitchToNonTargetLineResetsToFirstPageWhileTargetLineFocusesTarget() {
        let targetEp45 = TargetEpisodeLocation(lineIndex: 0, episodeIndex: 44)
        let counts = [60, 50]

        // Switching manually to Line B (no target) starts at page 0, offset 0
        let lineB = EpisodePaginationPlanner.reconcileLineChange(
            newLineIndex: 1,
            pendingJumpTarget: nil,
            target: targetEp45,
            lineEpisodeCounts: counts,
            descending: false
        )
        XCTAssertFalse(lineB.consumedPendingJump)
        XCTAssertEqual(lineB.state.lineIndex, 1)
        XCTAssertEqual(lineB.state.pageIndex, 0)
        XCTAssertEqual(lineB.state.focusedEpisodeOffset, 0)

        // Switching manually back to Line A lands directly on target EP 45's page (Page 3)
        let lineA = EpisodePaginationPlanner.reconcileLineChange(
            newLineIndex: 0,
            pendingJumpTarget: nil,
            target: targetEp45,
            lineEpisodeCounts: counts,
            descending: false
        )
        XCTAssertEqual(lineA.state.lineIndex, 0)
        XCTAssertEqual(lineA.state.pageIndex, 2)
        XCTAssertEqual(lineA.state.focusedEpisodeOffset, 44)
    }

    // MARK: - Multi-Layer Back Navigation Focus Restoration

    func testMultiLayerBackFocusRestorationPlayerToDetailToPosterWall() {
        // Layer 1: Returning from EpisodeSelectionView without starting playback restores the button that opened it
        let backFromPicker = FocusRestorationPlanner.resolveAfterEpisodeSelectionDismiss(
            lastFocusBeforeModal: .allEpisodes,
            currentLineIndex: 0,
            visibleRailEpisodeOffsets: Array(0..<12)
        )
        XCTAssertEqual(backFromPicker, .allEpisodes)

        // Layer 2a: Returning from Player after launching EP 6 directly (even if exited before history ticked)
        let backToOriginalEp = FocusRestorationPlanner.resolveAfterPlayerDismiss(
            lastFocusBeforeModal: .episode(lineIndex: 0, episodeIndex: 5),
            lastPlayedLineIndex: 0,
            lastPlayedEpisodeIndex: 5,
            savedHistoryLineIndex: nil,
            savedHistoryEpisodeIndex: nil,
            currentLineIndex: 0,
            visibleRailEpisodeOffsets: Array(0..<12)
        )
        XCTAssertEqual(backToOriginalEp, .episode(lineIndex: 0, episodeIndex: 5))

        // Layer 2b: User switched inside player from EP 6 to EP 45 -> Detail quick rail now centers around EP 45
        let backToWatchedEp45 = FocusRestorationPlanner.resolveAfterPlayerDismiss(
            lastFocusBeforeModal: .episode(lineIndex: 0, episodeIndex: 5),
            lastPlayedLineIndex: 0,
            lastPlayedEpisodeIndex: 5,
            savedHistoryLineIndex: 0,
            savedHistoryEpisodeIndex: 44,
            currentLineIndex: 0,
            visibleRailEpisodeOffsets: Array(43..<55)
        )
        XCTAssertEqual(backToWatchedEp45, .episode(lineIndex: 0, episodeIndex: 44))

        // Layer 2c: Launched from Hero Play button and watched EP 1 (not an episode tile) -> focuses watched episode or play cleanly
        let backFromPlayButton = FocusRestorationPlanner.resolveAfterPlayerDismiss(
            lastFocusBeforeModal: .play,
            lastPlayedLineIndex: 0,
            lastPlayedEpisodeIndex: 0,
            savedHistoryLineIndex: 0,
            savedHistoryEpisodeIndex: 0,
            currentLineIndex: 0,
            visibleRailEpisodeOffsets: Array(0..<12)
        )
        XCTAssertEqual(backFromPlayButton, .episode(lineIndex: 0, episodeIndex: 0))

        // Layer 3: Returning from DetailView back to Discover / Library / Search restores the exact original poster card
        let restoredPoster = FocusRestorationPlanner.resolvePosterCardReturn(
            lastOpenedKey: "site_a\n42",
            availableKeys: ["site_a\n10", "site_a\n42", "site_b\n42"]
        )
        XCTAssertEqual(restoredPoster, "site_a\n42")

        let removedPoster = FocusRestorationPlanner.resolvePosterCardReturn(
            lastOpenedKey: "site_a\n99",
            availableKeys: ["site_a\n10", "site_a\n42"]
        )
        XCTAssertNil(removedPoster)
    }
}

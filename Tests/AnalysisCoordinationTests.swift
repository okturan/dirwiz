import Foundation
import Testing
@testable import DirWizCore
@testable import DirWizUI

@Suite("Analysis Coordination Tests")
struct AnalysisCoordinationTests {
    @MainActor
    @Test("heavy task gate blocks overlapping work")
    func heavyTaskGateBlocksOverlaps() {
        let state = AppState()
        state.fileTree = FileTree()

        #expect(state.canStartHeavyTask(.duplicateScan))
        #expect(state.canStartHeavyTask(.hardlinkScan))
        #expect(state.canStartHeavyTask(.spaceAnalysis))
        #expect(state.canStartHeavyTask(.iCloudAnalysis))
        #expect(state.canStartHeavyTask(.apfsQuery))
        #expect(state.canStartHeavyTask(.cloneCheck))
        #expect(state.canStartHeavyTask(.bundleSizing))
        #expect(state.canStartHeavyTask(.applyChanges))

        state.hardlink.isHardlinkScanRunning = true
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.apfsQuery))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))
        #expect(!state.canStartHeavyTask(.applyChanges))

        state.hardlink.isHardlinkScanRunning = false
        state.isAPFSQueryRunning = true
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))
        #expect(!state.canStartHeavyTask(.applyChanges))

        state.isAPFSQueryRunning = false
        state.isApplyingChanges = true
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.apfsQuery))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))
        #expect(!state.canStartHeavyTask(.applyChanges))
    }

    @MainActor
    @Test("scan progress blocks heavy analysis launch")
    func filesystemScanBlocksHeavyAnalysisLaunch() {
        let state = AppState()
        state.fileTree = FileTree()
        state.scanProgress.isScanning = true

        for kind in AppState.HeavyTaskKind.allCases {
            #expect(!state.canStartHeavyTask(kind))
        }
    }

    @MainActor
    @Test("reset clears analysis run state and progress")
    func resetClearsAnalysisState() {
        let state = AppState()
        state.fileTree = FileTree()
        state.duplicate.isDuplicateScanRunning = true
        state.hardlink.hardlinkGroups = [HardlinkGroup(inode: 1, device: 1, fileSize: 100, paths: ["/a", "/b"])]
        state.hardlink.hardlinkExpandedGroups = [UUID()]
        state.hardlink.hardlinkProgress = (5, 12)
        state.hardlink.isHardlinkScanRunning = true
        state.spaceAnalysisProgress = (2, 3)
        state.isSpaceAnalysisRunning = true
        state.isFileAgeRunning = true
        state.isSizeDistRunning = true
        state.isICloudAnalysisRunning = true
        state.isAPFSQueryRunning = true
        state.isCloneCheckRunning = true
        state.isBundleSizingRunning = true
        state.isApplyingChanges = true

        state.resetForNewScan()

        #expect(!state.duplicate.isDuplicateScanRunning)
        #expect(state.hardlink.hardlinkGroups.isEmpty)
        #expect(state.hardlink.hardlinkExpandedGroups.isEmpty)
        #expect(state.hardlink.hardlinkProgress.processed == 0)
        #expect(state.hardlink.hardlinkProgress.total == 0)
        #expect(!state.hardlink.isHardlinkScanRunning)
        #expect(state.spaceAnalysisProgress.completed == 0)
        #expect(state.spaceAnalysisProgress.total == 0)
        #expect(!state.isSpaceAnalysisRunning)
        #expect(!state.isFileAgeRunning)
        #expect(!state.isSizeDistRunning)
        #expect(!state.isICloudAnalysisRunning)
        #expect(!state.isAPFSQueryRunning)
        #expect(!state.isCloneCheckRunning)
        #expect(!state.isBundleSizingRunning)
        #expect(!state.isApplyingChanges)
        #expect(state.activeHeavyTask == nil)
    }

    @MainActor
    @Test("HardlinkState.reset restores defaults")
    func hardlinkStateResetRestoresDefaults() {
        let hardlink = HardlinkState()
        hardlink.hardlinkGroups = [HardlinkGroup(inode: 1, device: 1, fileSize: 100, paths: ["/a", "/b"])]
        hardlink.hardlinkExpandedGroups = [UUID()]
        hardlink.hardlinkProgress = (5, 12)
        hardlink.isHardlinkScanRunning = true

        hardlink.reset()

        #expect(hardlink.hardlinkGroups.isEmpty)
        #expect(hardlink.hardlinkExpandedGroups.isEmpty)
        #expect(hardlink.hardlinkProgress.processed == 0)
        #expect(hardlink.hardlinkProgress.total == 0)
        #expect(!hardlink.isHardlinkScanRunning)
    }

    @MainActor
    @Test("reset clears the last-scan summary")
    func resetClearsLastScanSummary() {
        let state = AppState()
        state.fileTree = FileTree()
        state.lastScanSummary = "Refreshed 3 folders from last scan in 0.4s"

        state.resetForNewScan()

        #expect(state.lastScanSummary == nil)
    }
}

// MARK: - ScanSummaryComposer (pure formatting, plan 031)

@Suite("Scan Summary Composer Tests")
struct ScanSummaryComposerTests {
    @Test("Warm summary reports refreshed folder count and elapsed seconds")
    func warmSummaryFormatsFoldersAndSeconds() {
        #expect(
            ScanSummaryComposer.warm(foldersRefreshed: 3, seconds: 0.4) ==
            "Refreshed 3 folders from last scan in 0.4s"
        )
        #expect(
            ScanSummaryComposer.warm(foldersRefreshed: 0, seconds: 1.25) ==
            "Refreshed 0 folders from last scan in 1.2s"
        )
    }

    @Test("Cold summary reports item count and elapsed seconds")
    func coldSummaryFormatsItemsAndSeconds() {
        #expect(
            ScanSummaryComposer.cold(items: 12345, seconds: 2.1) ==
            "Scanned 12345 items in 2.1s"
        )
        #expect(
            ScanSummaryComposer.cold(items: 0, seconds: 0.05) ==
            "Scanned 0 items in 0.1s"
        )
    }

    @Test("Cold-with-reason summary appends the human-readable fallback reason")
    func coldWithReasonAppendsReason() {
        #expect(
            ScanSummaryComposer.coldWithReason(
                items: 12345, seconds: 2.1, reason: "312 folders (38%) changed since last scan"
            ) ==
            "Scanned 12345 items in 2.1s — full scan: 312 folders (38%) changed since last scan"
        )
        #expect(
            ScanSummaryComposer.coldWithReason(items: 0, seconds: 0.05, reason: "change journal unavailable") ==
            "Scanned 0 items in 0.1s — full scan: change journal unavailable"
        )
    }

    // MARK: - stale / staleBadge (plan 036)

    @Test("Sub-minute ages read as \"just now\", same discipline as the CLI diff report (plan 016)")
    func staleSubMinuteAgeReadsAsJustNow() {
        let now = Date()
        #expect(ScanSummaryComposer.stale(savedAt: now, now: now) == "Showing last scan · just now")
        #expect(
            ScanSummaryComposer.stale(savedAt: now.addingTimeInterval(-59), now: now) ==
            "Showing last scan · just now"
        )
    }

    @Test("Ages of a minute or more defer to RelativeDateTimeFormatter, not \"just now\"")
    func staleOlderAgeUsesRelativeFormatter() {
        let now = Date()
        let anHourAgo = now.addingTimeInterval(-3600)
        let result = ScanSummaryComposer.stale(savedAt: anHourAgo, now: now)
        #expect(result.hasPrefix("Showing last scan · "))
        #expect(!result.contains("just now"))
    }

    @Test("staleBadge appends an updating suffix while a refresh is in flight")
    func staleBadgeAppendsUpdatingSuffixWhileRefreshing() {
        let now = Date()
        #expect(
            ScanSummaryComposer.staleBadge(savedAt: now, isRefreshing: true, wasCancelled: false, now: now) ==
            "Showing last scan · just now — updating…"
        )
    }

    @Test("staleBadge appends a cancelled suffix once a refresh was cancelled")
    func staleBadgeAppendsCancelledSuffixAfterCancellation() {
        let now = Date()
        #expect(
            ScanSummaryComposer.staleBadge(savedAt: now, isRefreshing: false, wasCancelled: true, now: now) ==
            "Showing last scan · just now — refresh cancelled"
        )
    }

    @Test("staleBadge has no suffix when neither refreshing nor cancelled")
    func staleBadgeHasNoSuffixWhenIdle() {
        let now = Date()
        #expect(
            ScanSummaryComposer.staleBadge(savedAt: now, isRefreshing: false, wasCancelled: false, now: now) ==
            "Showing last scan · just now"
        )
    }

    @Test("staleBadge prefers the updating suffix if both flags are somehow true")
    func staleBadgePrefersUpdatingWhenBothFlagsTrue() {
        let now = Date()
        #expect(
            ScanSummaryComposer.staleBadge(savedAt: now, isRefreshing: true, wasCancelled: true, now: now) ==
            "Showing last scan · just now — updating…"
        )
    }
}

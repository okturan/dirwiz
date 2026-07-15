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

        state.hardlink.isHardlinkScanRunning = true
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.apfsQuery))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))

        state.hardlink.isHardlinkScanRunning = false
        state.isAPFSQueryRunning = true
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))
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
}

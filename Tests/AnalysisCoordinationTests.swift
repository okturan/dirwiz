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

        state.isHardlinkScanRunning = true
        #expect(!state.canStartHeavyTask(.hardlinkScan))
        #expect(!state.canStartHeavyTask(.duplicateScan))
        #expect(!state.canStartHeavyTask(.spaceAnalysis))
        #expect(!state.canStartHeavyTask(.iCloudAnalysis))
        #expect(!state.canStartHeavyTask(.apfsQuery))
        #expect(!state.canStartHeavyTask(.cloneCheck))
        #expect(!state.canStartHeavyTask(.bundleSizing))

        state.isHardlinkScanRunning = false
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
        state.hardlinkProgress = (5, 12)
        state.isHardlinkScanRunning = true
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
        #expect(state.hardlinkProgress.processed == 0)
        #expect(state.hardlinkProgress.total == 0)
        #expect(!state.isHardlinkScanRunning)
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
}

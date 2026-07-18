import Foundation
import DirWizCore
import OSLog

private let log = Logger(subsystem: "com.dirwiz", category: "AppState")

extension AppState {
    private enum SpaceAnalysisStepResult {
        case space(SpaceAnalysisResult)
        case fileStats(FileAgeResult, SizeDistributionResult)
    }

    // MARK: - Space Analysis

    /// Run space categorization, file age, and size distribution analysis in parallel.
    public func startSpaceAnalysis() {
        guard canStartHeavyTask(.spaceAnalysis), let tree = fileTree else { return }
        beginSpaceAnalysis(tree: tree, token: scanToken)
    }

    private func beginSpaceAnalysis(tree: FileTree, token: UInt64) {
        spaceAnalysisTask?.cancel()
        isSpaceAnalysisRunning = true
        isFileAgeRunning = true
        isSizeDistRunning = true
        spaceAnalysisProgress = (0, 2)

        spaceAnalysisTask = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: SpaceAnalysisStepResult.self) { group in
                group.addTask { .space(await SpaceAnalyzer().analyze(tree: tree)) }
                group.addTask {
                    let (age, size) = await CombinedFileStatsAnalyzer().analyze(tree: tree)
                    return .fileStats(age, size)
                }

                var completed = 0
                for await result in group {
                    completed += 1
                    let completedCount = completed
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        switch result {
                        case .space(let spaceResult):
                            self.spaceAnalysis = spaceResult
                        case .fileStats(let ageResult, let sizeResult):
                            self.fileAgeResult = ageResult
                            self.isFileAgeRunning = false
                            self.sizeDistribution = sizeResult
                            self.isSizeDistRunning = false
                        }
                        self.spaceAnalysisProgress = (completedCount, 2)
                    }
                }
            }

            await MainActor.run {
                guard self.scanToken == token else { return }
                self.isSpaceAnalysisRunning = false
                self.isFileAgeRunning = false
                self.isSizeDistRunning = false
                self.spaceAnalysisTask = nil
            }
        }
    }

    // MARK: - iCloud Analysis

    public func startICloudAnalysis() {
        guard canStartHeavyTask(.iCloudAnalysis), let tree = fileTree else { return }
        beginICloudAnalysis(tree: tree, token: scanToken)
    }

    private func beginICloudAnalysis(tree: FileTree, token: UInt64) {
        iCloudAnalysisTask?.cancel()
        isICloudAnalysisRunning = true

        iCloudAnalysisTask = Task.detached(priority: .userInitiated) {
            let result = await iCloudAnalyzer().analyze(tree: tree)
            await MainActor.run {
                guard self.scanToken == token else { return }
                self.iCloudResult = result
                self.isICloudAnalysisRunning = false
                self.iCloudAnalysisTask = nil
            }
        }
    }

    // MARK: - APFS Intelligence

    public func queryAPFSInfo() {
        guard canStartHeavyTask(.apfsQuery), let tree = fileTree else { return }
        beginAPFSQuery(volumePath: tree.path(at: 0), token: scanToken)
    }

    private func beginAPFSQuery(volumePath: String, token: UInt64) {
        apfsQueryTask?.cancel()
        isAPFSQueryRunning = true

        apfsQueryTask = Task.detached(priority: .utility) {
            let apfs = APFSIntelligence()
            let info = await apfs.analyze(volumePath: volumePath)
            await MainActor.run {
                guard self.scanToken == token else { return }
                self.purgeableSpace = info.purgeableSpace
                self.tmSnapshots = info.tmSnapshots
                self.isAPFSQueryRunning = false
                self.apfsQueryTask = nil
            }
        }
    }

    /// Check duplicate groups for APFS clones.
    public func checkClonesForDuplicates() {
        guard canStartHeavyTask(.cloneCheck), !duplicate.duplicateGroups.isEmpty else { return }
        beginCloneCheck(groups: duplicate.duplicateGroups, token: scanToken)
    }

    private func beginCloneCheck(groups: [DuplicateGroup], token: UInt64) {
        cloneCheckTask?.cancel()
        isCloneCheckRunning = true

        cloneCheckTask = Task.detached(priority: .userInitiated) {
            let results = await APFSIntelligence().checkClones(groups: groups)
            await MainActor.run {
                guard self.scanToken == token else { return }
                self.cloneResults = results
                self.isCloneCheckRunning = false
                self.cloneCheckTask = nil
            }
        }
    }

    // MARK: - FSEvents Monitoring

    public func toggleFSMonitoring() {
        if isFSMonitoringActive {
            fsEventsMonitor?.stop()
            fsEventsMonitor = nil
            isFSMonitoringActive = false
        } else {
            guard let tree = fileTree else { return }
            let rootPath = tree.path(at: 0)
            let monitor = FSEventsMonitor(watchPath: rootPath)
            monitor.start { [weak self] changes in
                Task { @MainActor in
                    self?.fsChanges = changes
                }
            }
            fsEventsMonitor = monitor
            isFSMonitoringActive = true
        }
    }

    /// Apply the accumulated FSEvents changes to the displayed tree incrementally — the
    /// "N folders changed · Refresh" badge's action (plan 037, user decision 3a: no
    /// auto-apply/debounced live mode, ever — the view only changes on an explicit click).
    /// Reuses the same `rescanSubtrees` splice engine `commitWarmStart` (AppState+Scan.swift)
    /// uses for warm start, but deliberately skips that flow's `scanProgress.isScanning` /
    /// `staleViewAsOf` plumbing: this patch is meant to feel instantaneous, and blanking the
    /// detail pane while it runs would defeat that. `isApplyingChanges` is the one honest
    /// signal it needs — it drives the badge's spinner and slots into the existing
    /// `HeavyTaskKind` exclusivity matrix via `.applyChanges`.
    ///
    /// No threshold gating: this is user-initiated and bounded by their own click, so an
    /// unusually large accumulated set just makes this one splice slower rather than being
    /// refused outright (unlike warm start's percentage-of-tree cold-fallback threshold).
    public func applyAccumulatedChanges() async {
        guard canStartHeavyTask(.applyChanges), !fsChanges.isEmpty, let tree = fileTree else { return }

        let token = scanToken
        isApplyingChanges = true

        let capture = ExplorationCapture.capture(
            tree: tree, selectedIndex: selectedNodeIndex, treemapRootIndex: navigation.treemapRootIndex
        )
        let rootPath = tree.path(at: 0)
        let targets = fsChanges.map(\.path)

        // Captured BEFORE the splice — same discipline as the cold-scan cache write-back
        // (AppState+Scan.swift): any change landing during the splice below is covered by
        // the *next* refresh's replay/monitor window rather than lost (029's
        // overlap-is-idempotent rationale).
        let eventIdBeforeSplice = FSEventsJournal.currentEventId()

        let scanner = FileScanner()
        let progress = ScanProgress()
        let startTime = CFAbsoluteTimeGetCurrent()
        let report = await scanner.rescanSubtrees(targets, tree: tree, progress: progress)

        // A new scan (warm or cold) superseded this apply while the splice was running.
        // In practice this can no longer happen — `AppState+Scan.swift`'s `startScan`
        // now declines to start any new scan while `isApplyingChanges` is true, the
        // symmetric counterpart of `canStartHeavyTask` refusing to start this apply while
        // a scan is running — so `scanToken` can't move during this `await`. Repairing
        // `isApplyingChanges` here anyway is cheap insurance: without it, an unforeseen
        // path to this guard would strand the flag true forever, permanently blocking
        // every `HeavyTaskKind` (`.applyChanges` is one of the cases `canStartHeavyTask`
        // checks) rather than just this one apply.
        guard scanToken == token else {
            isApplyingChanges = false
            return
        }

        // Failure honesty (same rule `commitWarmStart` applies to its own patch): an
        // unresolved path, or every target collapsing to the tree root because nothing
        // narrower survived resolution, means the patch can't be trusted — prefer a full
        // refresh over publishing a half-applied tree. `startFullRescan()` is 036-safe.
        guard report.unresolvedPaths.isEmpty, !report.rescannedRoots.contains(rootPath) else {
            isApplyingChanges = false
            startFullRescan()
            return
        }

        // This flow's scanner isn't registered with `scanSession` (see the doc comment
        // above), so nothing in the UI can cancel it directly today — but the enclosing
        // Task could still be cancelled some other way (e.g. the view task it runs on
        // going away). Leave `fsChanges`/the cache untouched rather than claiming full
        // coverage over a possibly-partial splice (028's rescan is idempotent, so simply
        // trying again later re-applies whatever this run didn't finish).
        guard !report.wasCancelled else {
            isApplyingChanges = false
            return
        }

        invalidateAfterTreeMutation(restoring: capture)
        computeExtensionStats()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        lastScanSummary = ScanSummaryComposer.warm(foldersRefreshed: report.rescannedRoots.count, seconds: elapsed)

        fsChanges = []
        fsEventsMonitor?.clearChanges()

        do {
            try TreeCache.save(tree: tree, lastEventId: eventIdBeforeSplice)
        } catch {
            log.error("TreeCache save failed after applying accumulated changes: \(error.localizedDescription, privacy: .public)")
        }

        isApplyingChanges = false
    }

    // MARK: - Storage Trends

    public func recordScanTrend() async {
        guard let tree = fileTree, let volumeURL = selectedVolume else { return }
        await Task.detached(priority: .background) {
            let trends = StorageTrends()
            try? await trends.recordScan(tree: tree, volumePath: volumeURL.path)
        }.value
    }

    public func loadStorageTrends() async {
        guard let tree = fileTree else { return }
        let rootPath = tree.path(at: 0)
        let history = await Task.detached(priority: .background) {
            let trends = StorageTrends()
            return (try? await trends.loadHistory(rootPath: rootPath)) ?? []
        }.value
        storageTrendHistory = history
    }

    public func runPostScanAnalyses(
        tree: FileTree,
        volumePath: String,
        token: UInt64
    ) async {
        guard scanToken == token else { return }
        await refreshStorageTrends(tree: tree, volumePath: volumePath, token: token)
        guard scanToken == token else { return }

        beginSpaceAnalysis(tree: tree, token: token)
        await spaceAnalysisTask?.value
        guard scanToken == token else { return }

        beginAPFSQuery(volumePath: tree.path(at: 0), token: token)
        await apfsQueryTask?.value
    }

    public func refreshStorageTrends(
        tree: FileTree,
        volumePath: String,
        token: UInt64
    ) async {
        let rootPath = tree.path(at: 0)
        let history = await Task.detached(priority: .background) {
            let trends = StorageTrends()
            try? await trends.recordScan(tree: tree, volumePath: volumePath)
            return (try? await trends.loadHistory(rootPath: rootPath)) ?? []
        }.value
        guard scanToken == token else { return }
        storageTrendHistory = history
    }

    // MARK: - Tree Actions

    /// Trash a node and update tree sizes in-place (no rescan needed).
    public func trashNode(at index: UInt32) async -> TrashResult {
        guard let tree = fileTree else {
            return TrashResult(
                originalPath: "", trashedURL: nil, nodeIndex: index,
                freedSize: 0, success: false, error: "No tree"
            )
        }
        let capture = ExplorationCapture.capture(
            tree: tree, selectedIndex: selectedNodeIndex, treemapRootIndex: navigation.treemapRootIndex
        )
        let result = await TreeActions().trash(nodeIndex: index, tree: tree)
        if result.success {
            invalidateAfterTreeMutation(restoring: capture)
        }
        return result
    }

    /// Batch-trash by path with ONE invalidation pass at the end.
    public func batchTrashPaths(_ paths: [String]) async -> BatchTrashResult {
        guard let tree = fileTree else { return BatchTrashResult(results: []) }
        let capture = ExplorationCapture.capture(
            tree: tree, selectedIndex: selectedNodeIndex, treemapRootIndex: navigation.treemapRootIndex
        )
        let result = await TreeActions().batchTrash(paths: paths, tree: tree)
        if result.successCount > 0 {
            invalidateAfterTreeMutation(restoring: capture)
        }
        return result
    }

    /// Reset all index-keyed OVERLAY state (search results, recency factors, temporal
    /// diff arrays — all recomputable, not part of "where was I") and bump the layout
    /// revision after a tree mutation. When `capture` was taken (via `ExplorationCapture`)
    /// BEFORE the mutation, also restores the user's interactive position — selection and
    /// treemap root/path — by re-resolving the captured paths against the post-mutation
    /// tree: paths survive `removeSubtree`'s index renumbering, indices don't. A surviving
    /// node keeps its (remapped) index; a deleted node's nearest surviving ancestor takes
    /// its place. Back/forward navigation stacks always clear — they're index histories
    /// with no path equivalent, and preserving them is complexity without user value.
    /// Shared by every tree-mutating action so the reset+restore list can't drift between
    /// callers.
    private func invalidateAfterTreeMutation(restoring capture: ExplorationCapture? = nil) {
        search.reset()
        temporalDiff.reset()
        recencyFactors = []
        recencyGeneration &+= 1
        isRecencyOverlayEnabled = false

        navigation.backStack.removeAll()
        navigation.forwardStack.removeAll()

        if let tree = fileTree {
            selectedNodeIndex = capture?.selectedPath.flatMap { ExplorationCapture.resolveOrAncestor($0, tree: tree) }
            let resolvedRoot = capture?.treemapRootPath.flatMap { ExplorationCapture.resolveOrAncestor($0, tree: tree) } ?? 0
            setTreemapRoot(resolvedRoot, recordHistory: false)
        } else {
            selectedNodeIndex = nil
            navigation.treemapRootIndex = 0
            navigation.treemapPath = [0]
        }

        scanProgress.publishCounters(forceLayoutRevision: true)
    }

    // MARK: - JSON Export

    public func exportJSON(to url: URL, options: JSONExportOptions = JSONExportOptions()) async throws {
        guard let tree = fileTree else { return }
        try await JSONExporter().export(tree: tree, to: url, options: options)
    }
}

import Foundation
import DirWizCore
import OSLog

private let log = Logger(subsystem: "com.dirwiz", category: "AppState")

extension AppState {
    private enum SpaceAnalysisStepResult {
        case space(SpaceAnalysisResult)
        case fileStats(FileAgeResult, SizeDistributionResult)
    }

    /// Priority for derived post-scan work. After an UNATTENDED scan (launch refresh,
    /// volume reconciliation) nobody is waiting on these full-tree walks, and running
    /// them at `.userInitiated` is why a self-launched DirWiz still spiked past 300% CPU
    /// after the scan itself was throttled. An explicit scan keeps the responsive tier.
    var derivedAnalysisPriority: TaskPriority {
        currentScanIsUnattended ? .utility : .userInitiated
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

        spaceAnalysisTask = Task.detached(priority: derivedAnalysisPriority) {
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

        iCloudAnalysisTask = Task.detached(priority: derivedAnalysisPriority) {
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

    /// Starts watching and begins the auto-apply loop. Called on every scan completion -
    /// cold, warm, and post-restore refresh - so the living view is simply always on.
    ///
    /// Plan 037's "decision 3a: no auto-apply, ever" is deliberately reversed here. That
    /// call was correct when the splice engine was new; it is now the same path warm start
    /// takes on every launch, with path-keyed exploration restore. Pausing is a preference,
    /// not the default.
    public func startLiveMonitoring() {
        stopLiveMonitoring()
        guard let tree = fileTree, tree.count > 0 else { return }

        let rootPath = tree.path(at: 0)
        let monitor = FSEventsMonitor(watchPath: rootPath)
        monitor.start { [weak self] changes in
            Task { @MainActor in
                guard let self else { return }
                self.fsChanges = changes
                // Every batch restarts the quiescence window, so a long burst (an install,
                // a build) splices once at the end rather than repeatedly throughout.
                self.lastLiveChangeAt = CFAbsoluteTimeGetCurrent()
            }
        }
        fsEventsMonitor = monitor
        isFSMonitoringActive = true
        startLiveRefreshLoop()
    }

    public func stopLiveMonitoring() {
        fsEventsMonitor?.stop()
        fsEventsMonitor = nil
        isFSMonitoringActive = false
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        liveRefreshDecision = .idle
    }

    /// Pause/resume auto-apply. Watching continues while paused, so the pending count keeps
    /// accumulating and the user can still apply manually - pausing suppresses the automatic
    /// splice, it does not blind the app.
    public func toggleLiveRefreshPaused() {
        liveRefreshPaused.toggle()
        evaluateLiveRefresh()
    }

    /// Retained for the existing Insights control path and tests; watching is now
    /// lifecycle-driven rather than user-toggled.
    public func toggleFSMonitoring() {
        if isFSMonitoringActive {
            stopLiveMonitoring()
        } else {
            startLiveMonitoring()
        }
    }

    private func startLiveRefreshLoop() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { @MainActor [weak self] in
            // One second is fine: the policy, not the tick rate, decides when to apply.
            // A faster tick would only re-evaluate the same verdict more often.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.evaluateLiveRefreshAndApply()
            }
        }
    }

    /// Recomputes the verdict without acting - used when a guard changes (pause toggled,
    /// overlay disabled) so the pill updates immediately instead of at the next tick.
    public func evaluateLiveRefresh() {
        liveRefreshDecision = LiveRefreshPolicy.decide(currentLiveRefreshInput())
    }

    private func currentLiveRefreshInput() -> LiveRefreshPolicy.Input {
        LiveRefreshPolicy.Input(
            pendingCount: fsChanges.count,
            now: CFAbsoluteTimeGetCurrent(),
            lastChangeAt: lastLiveChangeAt,
            lastAppliedAt: lastLiveApplyAt,
            isPaused: liveRefreshPaused,
            isScanning: scanProgress.isScanning,
            canStartHeavyTask: canStartHeavyTask(.applyChanges),
            isTemporalDiffActive: temporalDiff.isTemporalDiffEnabled
        )
    }

    private func evaluateLiveRefreshAndApply() async {
        let decision = LiveRefreshPolicy.decide(currentLiveRefreshInput())
        liveRefreshDecision = decision
        guard decision == .apply else { return }

        await applyAccumulatedChanges()
    }

    /// Apply the accumulated FSEvents changes to the displayed tree incrementally - the
    /// living view's automatic (or explicitly resumed) patch action. Reuses the same
    /// `rescanSubtrees` splice engine `commitWarmStart` (AppState+Scan.swift) uses for warm
    /// start, but deliberately skips that flow's `scanProgress.isScanning` / `staleViewAsOf`
    /// plumbing: this is not a new scan, and blanking the detail pane would defeat the live
    /// view. `isApplyingChanges` is the one honest
    /// signal it needs - it drives the badge's spinner and slots into the existing
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
        // Same shallow scoping as warm start: a directory accumulated only through
        // file→parent reduction needs one level reconciled, not its whole subtree -
        // without this, every `~/.DS_Store` write re-staged the entire home folder.
        let shallowTargets = Set(fsChanges.filter { !$0.hasDirectoryEvent }.map(\.path))

        // Captured BEFORE the splice - same discipline as the cold-scan cache write-back
        // (AppState+Scan.swift): any change landing during the splice below is covered by
        // the *next* refresh's replay/monitor window rather than lost (029's
        // overlap-is-idempotent rationale).
        let eventIdBeforeSplice = FSEventsJournal.currentEventId()

        let scanner = FileScanner()
        let progress = ScanProgress()
        let report = await scanner.rescanSubtrees(
            targets, tree: tree, progress: progress, shallowTargets: shallowTargets,
            // Unattended work: utility QoS and half the worker pool, so a live apply
            // yields to whatever the user is actually doing (see `.background`).
            options: .background
        )

        // A new scan (warm or cold) superseded this apply while the splice was running.
        // In practice this can no longer happen - `AppState+Scan.swift`'s `startScan`
        // now declines to start any new scan while `isApplyingChanges` is true, the
        // symmetric counterpart of `canStartHeavyTask` refusing to start this apply while
        // a scan is running - so `scanToken` can't move during this `await`. Repairing
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
        // narrower survived resolution, means the patch can't be trusted - prefer a full
        // refresh over publishing a half-applied tree. `startFullRescan()` is 036-safe.
        // A root-level SHALLOW reconcile is a successful in-place patch, not the
        // "nothing narrower resolved" failure this guard exists for.
        let rootLevelFailure = report.rescannedRoots.contains(rootPath)
            && !report.shallowRoots.contains(rootPath)
        guard report.unresolvedPaths.isEmpty, !rootLevelFailure else {
            isApplyingChanges = false
            startFullRescan()
            return
        }

        // This flow's scanner isn't registered with `scanSession` (see the doc comment
        // above), so nothing in the UI can cancel it directly today - but the enclosing
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

        fsChanges = []
        fsEventsMonitor?.clearChanges()

        // Re-serializing and checksumming the whole tree after every ~10 second splice
        // was the single largest background cost measured (~650 ms of CPU per apply on
        // a 4.6M-item volume). Skipping a save leaves the previous atomic cache and its
        // OLDER event id in place, so the next launch simply replays a wider window -
        // idempotent by design, and never advances the horizon past real work.
        let now = CFAbsoluteTimeGetCurrent()
        if LiveDerivedWorkPolicy.shouldRun(
            lastRunAt: lastLiveCacheSaveAt,
            now: now,
            minimumInterval: LiveDerivedWorkPolicy.cacheSaveMinimumInterval
        ) {
            do {
                try TreeCache.save(tree: tree, lastEventId: eventIdBeforeSplice)
                lastLiveCacheSaveAt = now
            } catch {
                log.error("TreeCache save failed after applying accumulated changes: \(error.localizedDescription, privacy: .public)")
            }
        }

        // A living-view splice is not a scan. Keep `lastScanSummary` and `scanProgress`
        // describing the same completed warm/cold scan instead of replacing only the
        // summary and leaving that scan's counters and elapsed time underneath it.
        isApplyingChanges = false
        lastLiveApplyAt = CFAbsoluteTimeGetCurrent()
        lastLiveChangeAt = nil
        liveRefreshGeneration &+= 1
        liveRefreshDecision = LiveRefreshPolicy.decide(currentLiveRefreshInput())
        refreshMenuBarVolumeStats()
    }

    // MARK: - Storage Trends

    public func recordScanTrend() async {
        guard let tree = fileTree, let volumeURL = selectedVolume else { return }
        guard tree.mountTraversalScope == .selectedVolume else {
            storageTrendHistory = []
            return
        }
        await Task.detached(priority: .background) {
            let trends = StorageTrends()
            try? await trends.recordScan(tree: tree, volumePath: volumeURL.path)
        }.value
    }

    public func loadStorageTrends() async {
        guard let tree = fileTree else { return }
        guard tree.mountTraversalScope == .selectedVolume else {
            storageTrendHistory = []
            return
        }
        let rootPath = tree.path(at: 0)
        let history = await Task.detached(priority: .background) {
            let trends = StorageTrends()
            return (try? await trends.loadHistory(rootPath: rootPath)) ?? []
        }.value
        storageTrendHistory = history
        refreshMenuBarVolumeStats()
    }

    /// Recompute hardlink groups from the current tree's scan-time link-count flags.
    /// Milliseconds on scanner/cache-produced trees (`linkCountsCaptured` fast path), so
    /// it runs automatically after every scan completion and tree mutation
    /// (always-on-hardlinks) instead of behind a button. Token-guarded like every other
    /// analysis so a stale run can't clobber a newer tree's results.
    /// - Parameter throttled: called from the post-mutation path, where a living-view
    ///   splice happens every few seconds. The whole-tree walk then runs only when the
    ///   Hardlinks tab is actually being viewed, or once the interval has elapsed;
    ///   otherwise the existing (path-keyed, still meaningful) groups stay on screen and
    ///   `hardlinkGroupsNeedRefresh` makes opening the tab recompute them.
    public func refreshHardlinkGroups(throttled: Bool = false) {
        guard let tree = fileTree, !tree.isEmpty else { return }
        if throttled {
            let isVisible = activeTab == .hardlinks
            guard LiveDerivedWorkPolicy.shouldRun(
                lastRunAt: lastHardlinkRefreshAt,
                now: CFAbsoluteTimeGetCurrent(),
                minimumInterval: LiveDerivedWorkPolicy.hardlinkRefreshMinimumInterval,
                isNeededNow: isVisible
            ) else {
                hardlinkGroupsNeedRefresh = true
                return
            }
        }
        hardlinkGroupsNeedRefresh = false
        lastHardlinkRefreshAt = CFAbsoluteTimeGetCurrent()
        hardlinkTask?.cancel()
        hardlinkToken &+= 1
        let token = hardlinkToken
        hardlink.isHardlinkScanRunning = true
        hardlink.hardlinkProgress = (0, 0)

        hardlinkTask = Task.detached(priority: .utility) {
            let groups = await HardlinkFinder().findHardlinks(in: tree)
            await MainActor.run {
                guard self.hardlinkToken == token else { return }
                self.hardlink.hardlinkGroups = groups
                self.hardlink.isHardlinkScanRunning = false
                self.hardlinkTask = nil
            }
        }
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
        guard tree.mountTraversalScope == .selectedVolume else {
            guard scanToken == token else { return }
            storageTrendHistory = []
            refreshMenuBarVolumeStats()
            return
        }
        let rootPath = tree.path(at: 0)
        let history = await Task.detached(priority: .background) {
            let trends = StorageTrends()
            try? await trends.recordScan(tree: tree, volumePath: volumePath)
            return (try? await trends.loadHistory(rootPath: rootPath)) ?? []
        }.value
        guard scanToken == token else { return }
        storageTrendHistory = history
        // This is the post-scan publish point used by the real scan supervisor. Keep the
        // ambient gauge and low-space latch on the same volume as the newly displayed tree.
        refreshMenuBarVolumeStats()
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
    /// diff arrays - all recomputable, not part of "where was I") and bump the layout
    /// revision after a tree mutation. When `capture` was taken (via `ExplorationCapture`)
    /// BEFORE the mutation, also restores the user's interactive position - selection and
    /// treemap root/path - by re-resolving the captured paths against the post-mutation
    /// tree: paths survive `removeSubtree`'s index renumbering, indices don't. A surviving
    /// node keeps its (remapped) index; a deleted node's nearest surviving ancestor takes
    /// its place. Back/forward navigation stacks always clear - they're index histories
    /// with no path equivalent, and preserving them is complexity without user value.
    /// Shared by every tree-mutating action so the reset+restore list can't drift between
    /// callers.
    /// `scheduleDerivedAnalyses` is an internal timing seam: the real-volume publication
    /// benchmark measures the synchronous UI boundary without leaving detached hardlink
    /// work running into the next matched sample. Production callers use the default.
    func invalidateAfterTreeMutation(
        restoring capture: ExplorationCapture? = nil,
        scheduleDerivedAnalyses: Bool = true
    ) {
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
        if scheduleDerivedAnalyses {
            // Throttled here specifically: this is the every-few-seconds living-view
            // mutation path. Scan completion (AppState+Scan.swift) still refreshes
            // unthrottled, so a finished scan always shows current hardlink groups.
            refreshHardlinkGroups(throttled: true)
        }

        // Candidate paths may have just been trashed. A stale candidate offering to verify
        // a file that no longer exists is worse than showing none, so drop and recompute.
        duplicate.resetInstant()
        if scheduleDerivedAnalyses {
            refreshInstantDuplicates()
        }
    }

    /// Recomputes the name+size duplicate candidates from the current tree.
    ///
    /// Pure in-memory over a snapshot - no file content is read - so it is cheap enough to
    /// run on tab open and after mutations without asking the user to press anything.
    public func refreshInstantDuplicates() {
        guard let tree = fileTree, !scanProgress.isScanning else { return }
        duplicate.instantToken &+= 1
        let token = duplicate.instantToken
        let minimumSize = duplicate.lastDuplicateScanMinimumSize
        duplicate.isInstantGroupingRunning = true

        Task.detached(priority: .userInitiated) {
            let report = InstantDuplicateFinder(minimumFileSize: minimumSize)
                .findCandidates(in: tree)
            await MainActor.run {
                // A newer pass (or a new scan) started while this one ran.
                guard token == self.duplicate.instantToken else { return }
                self.duplicate.isInstantGroupingRunning = false
                guard report.completed else { return }
                self.duplicate.instantCandidates = report.candidates
                self.duplicate.instantFilesConsidered = report.filesConsidered
                self.duplicate.instantElapsedMs = report.elapsedTime * 1000
                self.duplicate.pruneVerifiedCandidates()
            }
        }
    }

    /// Byte-verifies one candidate and promotes whatever is genuinely identical.
    public func verifyInstantCandidate(_ candidate: InstantDuplicateCandidate) {
        guard !duplicate.verifyingCandidateIDs.contains(candidate.id) else { return }
        duplicate.verifyingCandidateIDs.insert(candidate.id)
        duplicate.rejectedCandidateIDs.remove(candidate.id)

        Task.detached(priority: .userInitiated) {
            let confirmed = InstantDuplicateVerifier.verify(candidate)
            await MainActor.run {
                self.duplicate.verifyingCandidateIDs.remove(candidate.id)
                if confirmed.isEmpty {
                    // Same name, same size, different bytes - a real answer, so say so
                    // instead of leaving a button that appears to have done nothing.
                    self.duplicate.rejectedCandidateIDs.insert(candidate.id)
                    self.duplicate.lastVerifyOutcome =
                        "\(candidate.name): same size, but the contents differ - not duplicates."
                    return
                }
                self.duplicate.duplicateGroups.append(contentsOf: confirmed)
                self.duplicate.duplicateGroups.sort { $0.wastedSpace > $1.wastedSpace }
                self.duplicate.instantCandidates.removeAll { $0.id == candidate.id }
                // Point at the result: the row leaves the candidate list and appears below
                // as a confirmed group, which reads as "it vanished" without this.
                for group in confirmed { self.duplicate.lastConfirmedGroupIDs.insert(group.id) }
                self.duplicate.duplicateExpandedGroups.formUnion(confirmed.map(\.id))
                let reclaimable = confirmed.reduce(UInt64(0)) { $0 + $1.wastedSpace }
                self.duplicate.lastVerifyOutcome =
                    "\(candidate.name): byte-for-byte identical. "
                    + SizeFormatter.shared.format(reclaimable) + " can be reclaimed - see Confirmed below."
            }
        }
    }

    /// Verifies every candidate. Cancellable, and results land as they are confirmed.
    public func verifyAllInstantCandidates() {
        let candidates = duplicate.instantCandidates
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            verifyInstantCandidate(candidate)
        }
    }

    // MARK: - JSON Export

    public func exportJSON(to url: URL, options: JSONExportOptions = JSONExportOptions()) async throws {
        guard let tree = fileTree else { return }
        try await JSONExporter().export(tree: tree, to: url, options: options)
    }
}

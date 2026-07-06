import Foundation
import DirWizCore

extension AppState {
    private enum SpaceAnalysisStepResult {
        case space(SpaceAnalysisResult)
        case fileAge(FileAgeResult)
        case sizeDistribution(SizeDistributionResult)
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
        spaceAnalysisProgress = (0, 3)

        spaceAnalysisTask = Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: SpaceAnalysisStepResult.self) { group in
                group.addTask { .space(await SpaceAnalyzer().analyze(tree: tree)) }
                group.addTask { .fileAge(await FileAgeAnalyzer().analyze(tree: tree)) }
                group.addTask { .sizeDistribution(await SizeDistributionAnalyzer().analyze(tree: tree)) }

                var completed = 0
                for await result in group {
                    completed += 1
                    let completedCount = completed
                    await MainActor.run {
                        guard self.scanToken == token else { return }
                        switch result {
                        case .space(let spaceResult):
                            self.spaceAnalysis = spaceResult
                        case .fileAge(let ageResult):
                            self.fileAgeResult = ageResult
                            self.isFileAgeRunning = false
                        case .sizeDistribution(let sizeResult):
                            self.sizeDistribution = sizeResult
                            self.isSizeDistRunning = false
                        }
                        self.spaceAnalysisProgress = (completedCount, 3)
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
        let result = await TreeActions().trash(nodeIndex: index, tree: tree)
        if result.success {
            selectedNodeIndex = nil
            navigation.reset()
            // removeSubtree renumbered all node indices — anything index-keyed is stale.
            search.reset()
            temporalDiff.reset()
            recencyFactors = []
            recencyGeneration &+= 1
            isRecencyOverlayEnabled = false
            scanProgress.publishCounters(forceLayoutRevision: true)
        }
        return result
    }

    // MARK: - JSON Export

    public func exportJSON(to url: URL, options: JSONExportOptions = JSONExportOptions()) async throws {
        guard let tree = fileTree else { return }
        try await JSONExporter().export(tree: tree, to: url, options: options)
    }
}

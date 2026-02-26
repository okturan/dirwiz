import Foundation

extension AppState {

    // MARK: - Recency

    /// Apply recency factors — discards stale results from a superseded scan.
    public func applyRecencyFactors(_ factors: [Float], token: UInt64) {
        guard token == recencyToken else { return }
        recencyFactors = factors
        recencyGeneration &+= 1
        isRecencyQueryRunning = false
    }

    /// Start a Spotlight recency query if one is not already running.
    public func startRecencyQueryIfNeeded() {
        guard !isRecencyQueryRunning, let tree = fileTree else { return }
        isRecencyQueryRunning = true
        recencyToken &+= 1
        let token = recencyToken
        let service = RecencyQueryService()
        Task {
            let factors = await service.queryRecency(tree: tree)
            await MainActor.run {
                self.applyRecencyFactors(factors, token: token)
            }
        }
    }

    // MARK: - Temporal Diff

    /// Build a snapshot from the current scan and persist it to disk.
    public func takeSnapshot() {
        guard !isSnapshotBuilding, let tree = fileTree else { return }
        isSnapshotBuilding = true
        Task.detached(priority: .utility) {
            let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)
            try? snapshot.save()
            await MainActor.run {
                self.temporalSnapshot = snapshot
                self.isSnapshotBuilding = false
            }
        }
    }

    /// Try to load a persisted snapshot matching the current scan root.
    public func loadSnapshotIfAvailable() {
        guard let tree = fileTree else { return }
        Task.detached(priority: .background) {
            let rootPath = tree.path(at: 0)
            guard let snapshot = try? TemporalSnapshot.load(for: rootPath) else { return }
            await MainActor.run {
                self.temporalSnapshot = snapshot
            }
        }
    }

    /// Apply a diff result — discards stale results from a superseded scan.
    public func applyTemporalDiff(_ result: TemporalDiffResult, token: UInt64) {
        guard token == temporalDiffToken else { return }
        temporalDiffKinds = result.kinds
        temporalDiffStrengths = result.strengths
        temporalDiffDeletedCounts = result.deletedByNode
        temporalDiffGeneration &+= 1
    }

    /// Start diff computation between the current tree and the loaded snapshot.
    public func startTemporalDiff() {
        guard let snapshot = temporalSnapshot, let tree = fileTree else { return }
        temporalDiffTask?.cancel()
        temporalDiffToken &+= 1
        let token = temporalDiffToken
        temporalDiffTask = Task.detached(priority: .utility) {
            let result = await TemporalDiffService.computeDiff(
                currentTree: tree, snapshot: snapshot)
            await MainActor.run {
                self.applyTemporalDiff(result, token: token)
            }
        }
    }
}

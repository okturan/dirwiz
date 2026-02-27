import Foundation
import OSLog

private let log = Logger(subsystem: "com.dirwiz", category: "AppState")

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
        recencyTask = Task {
            let factors = await service.queryRecency(tree: tree)
            // Don't apply results if cancelled (superseded scan).
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.applyRecencyFactors(factors, token: token)
            }
        }
    }

    // MARK: - Temporal Diff

    /// Build a snapshot from the current scan and persist it to disk.
    /// Captures the current scanToken to discard results from a stale tree
    /// if a rescan occurs while the snapshot is being built.
    public func takeSnapshot() {
        guard !temporalDiff.isSnapshotBuilding, let tree = fileTree else { return }
        temporalDiff.isSnapshotBuilding = true
        let token = scanToken
        Task.detached(priority: .utility) {
            let snapshot = await TemporalDiffService.buildSnapshot(tree: tree)
            let saveError: String? = {
                do {
                    try snapshot.save()
                    return nil
                } catch {
                    let msg = "Failed to save snapshot: \(error.localizedDescription)"
                    log.error("TemporalSnapshot save failed: \(msg)")
                    return msg
                }
            }()
            await MainActor.run {
                // Discard if a new scan started while building.
                guard self.scanToken == token else {
                    self.temporalDiff.isSnapshotBuilding = false
                    return
                }
                self.temporalDiff.temporalSnapshot = snapshot
                self.temporalDiff.isSnapshotBuilding = false
                if let msg = saveError {
                    self.scanProgress.error = msg
                }
            }
        }
    }

    /// Try to load a persisted snapshot matching the current scan root.
    public func loadSnapshotIfAvailable() {
        guard let tree = fileTree else {
            temporalDiff.temporalSnapshot = nil
            return
        }
        let token = scanToken
        Task.detached(priority: .background) {
            let rootPath = tree.path(at: 0)
            let snapshot = try? TemporalSnapshot.load(for: rootPath)
            await MainActor.run {
                // Discard stale load if another scan started while I/O was running.
                guard self.scanToken == token else { return }
                self.temporalDiff.temporalSnapshot = snapshot
                if snapshot == nil {
                    self.temporalDiff.isTemporalDiffEnabled = false
                }
            }
        }
    }

    /// Apply a diff result — discards stale results from a superseded scan.
    public func applyTemporalDiff(_ result: TemporalDiffResult, token: UInt64) {
        guard token == temporalDiffToken else { return }
        temporalDiff.temporalDiffKinds = result.kinds
        temporalDiff.temporalDiffStrengths = result.strengths
        temporalDiff.temporalDiffDeletedCounts = result.deletedByNode
        temporalDiff.temporalDiffGeneration &+= 1
    }

    /// Start diff computation between the current tree and the loaded snapshot.
    public func startTemporalDiff() {
        guard let snapshot = temporalDiff.temporalSnapshot, let tree = fileTree else { return }
        let currentRootPath = tree.path(at: 0)
        guard snapshot.meta.rootPath == currentRootPath else {
            temporalDiff.isTemporalDiffEnabled = false
            temporalDiff.temporalDiffKinds = []
            temporalDiff.temporalDiffStrengths = []
            temporalDiff.temporalDiffDeletedCounts = [:]
            temporalDiff.temporalDiffGeneration &+= 1
            return
        }
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

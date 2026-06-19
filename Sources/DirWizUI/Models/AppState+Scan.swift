import DirWizCore
import Foundation

extension AppState {
    public func startSelectedVolumeScan() {
        guard let volumeURL = selectedVolume else { return }
        startScan(volumeURL: volumeURL, runPostScanAnalyses: true)
    }

    public func cancelScan() {
        scanSession.cancelActiveScan()
    }

    /// Rescan the selected volume from scratch (e.g., after trashing a file).
    public func rescanVolume() {
        guard let volumeURL = selectedVolume else { return }
        startScan(volumeURL: volumeURL, runPostScanAnalyses: false)
    }

    private func startScan(volumeURL: URL, runPostScanAnalyses shouldRunPostScanAnalyses: Bool) {
        scanSession.cancelActiveScan()

        let scanner = FileScanner(computeBundleSizes: false)
        let tree = FileTree()
        let path = volumeURL.path

        fileTree = tree
        resetForNewScan()
        activeTab = .treeView
        scanSession.markStarted(scanner: scanner)
        let token = scanToken

        Task {
            await scanner.scan(path: path, progress: scanProgress, tree: tree)
            let handoff = await MainActor.run { () -> (scanCompleted: Bool, sizingTask: Task<Void, Never>?) in
                guard self.scanToken == token else { return (false, nil) }
                self.scanSession.markFinished()
                guard !self.scanProgress.isCancelled else { return (false, nil) }
                self.setTreemapRoot(0, recordHistory: false)
                self.computeExtensionStats()
                self.beginDeferredBundleSizing(scanner: scanner, tree: tree, token: token)
                return (true, self.bundleSizingTask)
            }

            if shouldRunPostScanAnalyses, handoff.scanCompleted {
                await handoff.sizingTask?.value
                await self.runPostScanAnalyses(tree: tree, volumePath: path, token: token)
            }
        }
    }

    private func beginDeferredBundleSizing(scanner: FileScanner, tree: FileTree, token: UInt64) {
        bundleSizingTask?.cancel()
        isBundleSizingRunning = true

        bundleSizingTask = Task.detached(priority: .utility) {
            let report = await scanner.resolveDeferredBundleSizes(in: tree)
            await MainActor.run {
                guard self.scanToken == token else { return }
                self.isBundleSizingRunning = false
                self.bundleSizingTask = nil
                guard !report.wasCancelled else { return }

                self.scanProgress.publishCounters(forceLayoutRevision: true)
                self.computeExtensionStats()
                if report.bundlesResolved > 0 {
                    self.scanProgress.totalSize = (tree.node(at: 0)?.fileSize ?? self.scanProgress.totalSize)
                    self.scanProgress.scannedAllocatedBytes = (tree.node(at: 0)?.allocatedSize ?? self.scanProgress.scannedAllocatedBytes)
                }
            }
        }
    }
}

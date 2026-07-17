import DirWizCore
import Foundation
import OSLog

private let log = Logger(subsystem: "com.dirwiz", category: "AppState")

/// Pure formatting for `AppState.lastScanSummary`, the one-line summary shown in
/// the sidebar's completed-scan block. Factored out so both variants (warm/cold)
/// are unit-testable without driving the full async scan pipeline.
enum ScanSummaryComposer {
    static func warm(foldersRefreshed: Int, seconds: TimeInterval) -> String {
        "Refreshed \(foldersRefreshed) folders from last scan in \(String(format: "%.1f", seconds))s"
    }

    static func cold(items: Int, seconds: TimeInterval) -> String {
        "Scanned \(items) items in \(String(format: "%.1f", seconds))s"
    }

    /// The cold flavor, with the human-readable reason a warm start didn't happen
    /// appended — so a fallback still reads as an answer ("why was this slow?") rather
    /// than silence in the logs.
    static func coldWithReason(items: Int, seconds: TimeInterval, reason: String) -> String {
        cold(items: items, seconds: seconds) + " — full scan: \(reason)"
    }
}

extension AppState {
    public func startSelectedVolumeScan() {
        guard let volumeURL = selectedVolume else { return }
        startScan(volumeURL: volumeURL, runPostScanAnalyses: true, forceCold: false)
    }

    /// Bypasses any cached tree and always performs a full cold scan — the "Full
    /// Rescan" escape hatch next to "Scan Volume", for when a warm start is suspected
    /// stale (e.g. Full Disk Access changed between sessions).
    public func startFullRescan() {
        guard let volumeURL = selectedVolume else { return }
        startScan(volumeURL: volumeURL, runPostScanAnalyses: true, forceCold: true)
    }

    public func cancelScan() {
        scanSession.cancelActiveScan()
    }

    /// Cheap existence check (no decode) for whether a warm-start cache is on disk for
    /// `path` — lets the UI show the "Full Rescan" affordance without paying for a full
    /// `TreeCache.load`.
    public func hasCachedTree(for path: String) -> Bool {
        FileManager.default.fileExists(atPath: TreeCache.cacheURL(for: path).path)
    }

    /// Rescan the selected volume from scratch (e.g., after trashing a file). Always
    /// cold — the caller already knows what changed (it just changed it), so a warm
    /// start's "what changed since the cache" question doesn't apply here.
    public func rescanVolume() {
        guard let volumeURL = selectedVolume else { return }
        startScan(volumeURL: volumeURL, runPostScanAnalyses: false, forceCold: true)
    }

    /// Entry point for every scan trigger. If a cache exists for `path` and warm start
    /// isn't disabled/forced off, attempts to replay the FSEvents journal and patch just
    /// what changed instead of a full enumeration. Any anomaly — no cache, a poisoned or
    /// oversized journal replay, an unresolved or root-level rescan target — falls back
    /// to exactly the cold flow below, unmodified.
    private func startScan(volumeURL: URL, runPostScanAnalyses shouldRunPostScanAnalyses: Bool, forceCold: Bool) {
        scanSession.cancelActiveScan()
        let path = volumeURL.path

        guard !forceCold,
              ProcessInfo.processInfo.environment["DIRWIZ_NO_WARM_START"] != "1",
              let cached = TreeCache.load(for: path) else {
            beginColdScan(path: path, runPostScanAnalyses: shouldRunPostScanAnalyses)
            return
        }

        // Bumps the session token now, before the async journal replay below, so a
        // second startScan() call during that gap supersedes this attempt instead of
        // racing it — the eventual commit (warm or cold) re-checks against this token.
        scanSession.invalidate()
        let attemptToken = scanSession.token

        Task {
            let replay = await FSEventsJournal.replay(root: path, since: cached.lastEventId)
            // A true folder count for the threshold, not the cache's raw node count —
            // computed fresh each attempt since the cached tree itself never changes here.
            let cachedDirectoryCount = Self.directoryCount(in: cached.tree)
            let decision = WarmStartPlanner.decide(
                cacheAvailable: true,
                replay: replay.outcome,
                cachedDirectoryCount: cachedDirectoryCount
            )

            guard self.scanSession.token == attemptToken else { return }

            switch decision {
            case .coldFallback(let reason):
                log.info("Warm start fallback for \(path, privacy: .public): \(reason, privacy: .public)")
                self.beginColdScan(path: path, runPostScanAnalyses: shouldRunPostScanAnalyses, coldFallbackReason: reason)
            case .warm(let targets):
                await self.commitWarmStart(
                    cached: cached,
                    path: path,
                    targets: targets,
                    newEventId: replay.newEventId,
                    runPostScanAnalyses: shouldRunPostScanAnalyses
                )
            }
        }
    }

    /// Publishes the cached tree, patches only the directories the journal says changed,
    /// and re-establishes the exact post-conditions a cold scan produces. Any sign the
    /// patch can't be trusted — an unresolved path, or a target that bottomed out at the
    /// root because nothing narrower resolved — abandons the warm attempt and restarts
    /// cold instead of publishing a partial result.
    private func commitWarmStart(
        cached: TreeCache.Payload,
        path: String,
        targets: [String],
        newEventId: UInt64,
        runPostScanAnalyses shouldRunPostScanAnalyses: Bool
    ) async {
        let tree = cached.tree
        let scanner = FileScanner()

        fileTree = tree
        resetForNewScan()
        activeTab = .treeView
        scanSession.markStarted(scanner: scanner)
        let token = scanToken
        scanProgress.isScanning = true
        scanProgress.currentPath = "Updating from last scan…"

        let startTime = CFAbsoluteTimeGetCurrent()
        let report = await scanner.rescanSubtrees(targets, tree: tree, progress: scanProgress)

        guard scanToken == token else { return }

        // A root-level target means some changed path couldn't resolve to anything
        // narrower than the scan root (028's `SubtreeRescanReport.rescannedRoots` doc) —
        // treat it the same as an unresolved path: prefer a full rescan over patching
        // the whole tree through the splice path it wasn't designed to replace wholesale.
        guard report.unresolvedPaths.isEmpty, !report.rescannedRoots.contains(path) else {
            log.info("Warm start abandoned mid-patch for \(path, privacy: .public); falling back to cold")
            beginColdScan(path: path, runPostScanAnalyses: shouldRunPostScanAnalyses)
            return
        }

        scanSession.markFinished()
        setTreemapRoot(0, recordHistory: false)
        computeExtensionStats()
        scanProgress.publishCounters(forceLayoutRevision: true)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let summary = ScanSummaryComposer.warm(foldersRefreshed: report.rescannedRoots.count, seconds: elapsed)
        scanProgress.isScanning = false
        scanProgress.scanComplete = true
        scanProgress.currentPath = summary
        lastScanSummary = summary

        do {
            try TreeCache.save(tree: tree, lastEventId: newEventId)
        } catch {
            log.error("TreeCache save failed after warm start: \(error.localizedDescription, privacy: .public)")
        }

        if shouldRunPostScanAnalyses {
            await runPostScanAnalyses(tree: tree, volumePath: path, token: token)
        }
    }

    /// Today's full enumeration — byte-for-byte the pre-warm-start flow. Reused both as
    /// the direct path (no cache, or "Full Rescan") and as the fallback whenever a warm
    /// attempt can't be trusted. `coldFallbackReason` is only set when this cold scan
    /// replaces a warm attempt the planner declined — surfaced in the completion summary
    /// so the fallback is legible instead of only a log line.
    private func beginColdScan(
        path: String,
        runPostScanAnalyses shouldRunPostScanAnalyses: Bool,
        coldFallbackReason: String? = nil
    ) {
        // Captured before the scan starts: any filesystem activity on this volume from
        // here on is exactly what the *next* warm start needs to replay.
        let eventIdAtScanStart = FSEventsJournal.currentEventId()

        let scanner = FileScanner(computeBundleSizes: false)
        let tree = FileTree()

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
                if let coldFallbackReason {
                    self.lastScanSummary = ScanSummaryComposer.coldWithReason(
                        items: tree.count, seconds: self.scanProgress.elapsedTime, reason: coldFallbackReason
                    )
                } else {
                    self.lastScanSummary = ScanSummaryComposer.cold(items: tree.count, seconds: self.scanProgress.elapsedTime)
                }
                self.beginDeferredBundleSizing(
                    scanner: scanner, tree: tree, token: token, eventIdAtScanStart: eventIdAtScanStart
                )
                return (true, self.bundleSizingTask)
            }

            if shouldRunPostScanAnalyses, handoff.scanCompleted {
                await handoff.sizingTask?.value
                await self.runPostScanAnalyses(tree: tree, volumePath: path, token: token)
            }
        }
    }

    /// One O(n) pass over the cached tree's snapshot counting directory nodes — the
    /// denominator for `WarmStartPlanner`'s percentage threshold. Not stored in the
    /// `TreeCache` header (that's a format change, out of scope here); cheap enough
    /// (~ms at millions of nodes) to recompute per warm-start attempt instead.
    private static func directoryCount(in tree: FileTree) -> Int {
        tree.nodesSnapshot().reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
    }

    private func beginDeferredBundleSizing(
        scanner: FileScanner, tree: FileTree, token: UInt64, eventIdAtScanStart: UInt64
    ) {
        bundleSizingTask?.cancel()
        isBundleSizingRunning = true

        bundleSizingTask = Task.detached(priority: .utility) {
            let report = await scanner.resolveDeferredBundleSizes(in: tree)
            let shouldSaveCache = await MainActor.run { () -> Bool in
                guard self.scanToken == token else { return false }
                self.isBundleSizingRunning = false
                self.bundleSizingTask = nil
                guard !report.wasCancelled else { return false }

                self.scanProgress.publishCounters(forceLayoutRevision: true)
                self.computeExtensionStats()
                if report.bundlesResolved > 0 {
                    self.scanProgress.totalSize = (tree.node(at: 0)?.fileSize ?? self.scanProgress.totalSize)
                    self.scanProgress.scannedAllocatedBytes = (tree.node(at: 0)?.allocatedSize ?? self.scanProgress.scannedAllocatedBytes)
                }
                return true
            }

            // Off-main and after the handoff above: sizes are final once bundle
            // resolution completes, so this is the earliest safe point to persist.
            // Save failures are logged, never surfaced — a missing/stale cache just
            // means the next scan falls back cold, exactly today's behavior.
            guard shouldSaveCache else { return }
            do {
                try TreeCache.save(tree: tree, lastEventId: eventIdAtScanStart)
            } catch {
                log.error("TreeCache save failed after cold scan: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

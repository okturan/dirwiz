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

    /// "Showing last scan · X ago" for a restored cache not yet freshened. `now` is
    /// injectable for deterministic tests; defaults to the real clock for callers.
    static func stale(savedAt: Date, now: Date = Date()) -> String {
        "Showing last scan · \(relativeDescription(of: savedAt, now: now))"
    }

    /// The stale badge shown while a restored view is displayed: the base `stale(...)`
    /// text plus a suffix describing what the in-flight (or just-ended) refresh is doing.
    /// `isRefreshing` wins over `wasCancelled` if somehow both are true.
    static func staleBadge(savedAt: Date, isRefreshing: Bool, wasCancelled: Bool, now: Date = Date()) -> String {
        let base = stale(savedAt: savedAt, now: now)
        if isRefreshing { return base + " — updating…" }
        if wasCancelled { return base + " — refresh cancelled" }
        return base
    }

    /// Sub-minute ages read as "just now" rather than a formatter's "in 0 seconds" —
    /// same discipline as the CLI's `diff` age rendering (plan 016).
    private static func relativeDescription(of date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        return abs(age) < 60
            ? "just now"
            : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

extension AppState {
    private static let lastScannedVolumePathKey = "lastScannedVolumePath"

    /// Human-readable stale-view badge text ("Showing last scan · X ago[ — updating…]"),
    /// or nil when no restored view is displayed. Computed live off `staleViewAsOf` and
    /// `scanProgress` rather than cached, so the relative time and refresh status stay
    /// current across repeated reads without AppState having to re-write a stored string
    /// on every progress tick.
    public var staleBadgeText: String? {
        guard let staleViewAsOf else { return nil }
        return ScanSummaryComposer.staleBadge(
            savedAt: staleViewAsOf,
            isRefreshing: scanProgress.isScanning,
            wasCancelled: scanProgress.isCancelled
        )
    }

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

    /// True while a scan flow has published its "preparing" `ScanProgress` (see
    /// `startScan`'s supervisor doc comment) but hasn't yet registered a real
    /// `FileScanner` — i.e. mid cache-lookup or FSEvents replay-wait. Distinguishes the
    /// sidebar/button's honest "Checking what changed…" sub-state from "Scanning…" once
    /// real enumeration work has actually begun, using only existing bookkeeping
    /// (`scanSession.activeScanner` is nil until `markStarted` registers one, and
    /// `cancelActiveScan()` now clears it immediately rather than leaving a stale
    /// reference behind).
    public var isPreparingScan: Bool {
        scanProgress.isScanning && scanSession.activeScanner == nil
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

    /// Called once from the app's launch entry point. Restores the last successfully
    /// scanned volume's cached tree instantly (no enumeration) and kicks off the normal
    /// scan flow behind it to freshen it — the auto-refresh stays behind a `staleViewAsOf`
    /// badge and never blanks the restored view (see `beginColdScan`/`commitWarmStart`'s
    /// preserve-behind-stale branches). A no-op, leaving today's empty launch state, when:
    /// the kill switch is set, nothing was scanned before, the volume is no longer
    /// mounted, the cache fails to load, or a tree is already displayed (guards against
    /// a duplicate call, e.g. a second `.onAppear`).
    public func restoreOnLaunch() {
        guard fileTree == nil else { return }
        guard ProcessInfo.processInfo.environment["DIRWIZ_NO_WARM_START"] != "1" else { return }
        guard let path = defaults.string(forKey: Self.lastScannedVolumePathKey), !path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let cached = TreeCache.load(for: path) else { return }

        let volumeURL = URL(fileURLWithPath: path)
        selectedVolume = volumeURL
        fileTree = cached.tree

        // Restore where the user left off (033/038): resolve the saved session's
        // selection and treemap root through `resolveOrAncestor` so a folder deleted
        // since last launch degrades to its nearest surviving ancestor instead of
        // restoring nothing. TreeTableView seeds its own `expandedPaths` from the same
        // session on appear (`seedExpansionFromSessionIfNeeded`) — nothing to do here for
        // expansion, which is view-local state AppState doesn't own.
        let session = sessionStore.load(forVolume: path)
        selectedNodeIndex = session?.selectedPath.flatMap {
            ExplorationCapture.resolveOrAncestor($0, tree: cached.tree)
        }
        let resolvedRoot = session?.treemapRootPath.flatMap {
            ExplorationCapture.resolveOrAncestor($0, tree: cached.tree)
        } ?? 0
        setTreemapRoot(resolvedRoot, recordHistory: false)

        computeExtensionStats()
        scanProgress.publishCounters(forceLayoutRevision: true)
        staleViewAsOf = cached.savedAt
        lastScanSummary = ScanSummaryComposer.stale(savedAt: cached.savedAt)

        startScan(volumeURL: volumeURL, runPostScanAnalyses: true, forceCold: false, preloadedCache: cached)
    }

    /// Entry point for every scan trigger (incl. `restoreOnLaunch`'s auto-refresh). If a
    /// cache exists for `path` and warm start isn't disabled/forced off, attempts to
    /// replay the FSEvents journal and patch just what changed instead of a full
    /// enumeration. Any anomaly — no cache, a poisoned or oversized journal replay, an
    /// unresolved or root-level rescan target — falls back to exactly the cold flow
    /// below, unmodified.
    ///
    /// **Scan-flow supervision invariant**: after any scan flow exits by ANY path
    /// (success, supersession, cancellation, warm→cold handoff, error), exactly one
    /// holds — (a) a newer flow has since published its own fresh `ScanProgress`, or (b)
    /// the currently-published `scanProgress.isScanning == false` and the sidebar
    /// reflects a terminal state (complete / cancelled / summary). This is enforced
    /// structurally, not per-path: entering this function ALWAYS, synchronously and
    /// unconditionally, bumps `scanSession`'s token and publishes a brand-new
    /// `ScanProgress` (the "preparing" state below) before doing anything else — so every
    /// later token-mismatch guard anywhere in the scan pipeline (`commitWarmStart`,
    /// `beginColdScan`, `beginDeferredBundleSizing`) is automatically safe: a mismatch can
    /// only exist because a NEWER call to this same function already replaced
    /// `scanProgress` with its own fresh instance first. New scan-adjacent flows must
    /// preserve this pairing (never bump `scanSession.invalidate()` without republishing
    /// `scanProgress` in the same synchronous step) and add a `ScanSupervisionTests` case.
    private func startScan(
        volumeURL: URL,
        runPostScanAnalyses shouldRunPostScanAnalyses: Bool,
        forceCold: Bool,
        preloadedCache: TreeCache.Payload? = nil
    ) {
        // Symmetric with `canStartHeavyTask(.applyChanges)` requiring `!isScanning`:
        // `applyAccumulatedChanges` splices the live tree with its own untracked scratch
        // scanner (not registered with `scanSession`), so rather than teaching this flow
        // to reach in and cancel it, a scan just declines to start during that brief,
        // user-initiated, bounded window. The user's click is simply a no-op; nothing to
        // repair since nothing here gets published.
        guard !isApplyingChanges else { return }

        scanSession.cancelActiveScan()
        // A new scan flow always supersedes any bundle-sizing pass left over from a
        // previous cold scan — it's scoped to that scan's own tree, which this flow is
        // about to replace. `resetForNewScan()`/`resetTreeDerivedState()` already cancel
        // it once a flow reaches that point, but doing it here too means a click landing
        // during THIS flow's own replay-wait doesn't leave stale bundle-sizing state
        // observable (and `canStartHeavyTask` blocked) for the whole wait.
        bundleSizingTask?.cancel()
        bundleSizingTask = nil
        isBundleSizingRunning = false

        let path = volumeURL.path

        let cached: TreeCache.Payload?
        if !forceCold, ProcessInfo.processInfo.environment["DIRWIZ_NO_WARM_START"] != "1" {
            // `preloadedCache` comes from `restoreOnLaunch()`, which already loaded and
            // published this exact payload's tree moments earlier — reusing it here
            // avoids decoding the same cache file from disk a second time.
            cached = preloadedCache ?? TreeCache.load(for: path)
        } else {
            cached = nil
        }

        // Publish the "preparing" ScanProgress now, unconditionally — see the supervision
        // invariant above. This is what makes the (possibly multi-second) FSEvents
        // replay-wait below visible instead of silent: `isScanning` flips true and
        // `currentPath` says what's happening immediately, before any async work has even
        // started. `estimatedTotalItems` is left at its fresh default (0) so
        // `fractionCompleted` reads indeterminate rather than a misleading 0%.
        scanSession.invalidate()
        scanProgress = ScanProgress()
        scanProgress.isScanning = true
        scanProgress.currentPath = cached != nil ? "Checking what changed…" : "Preparing scan…"
        let attemptToken = scanSession.token

        guard let cached else {
            beginColdScan(
                path: path,
                runPostScanAnalyses: shouldRunPostScanAnalyses,
                preservedExploration: captureExplorationIfPreserving()
            )
            return
        }

        Task {
            let replay = await FSEventsJournal.replay(root: path, since: cached.lastEventId)
            // A true folder count for the threshold, not the cache's raw node count —
            // computed fresh each attempt since the cached tree itself never changes here.
            let cachedDirectoryCount = Self.directoryCount(in: cached.tree)
            // Cost-based rule (plan 042): estimate how much of the cached tree the
            // changed roots actually represent, not just how many of them there are — a
            // handful of collapsed roots can still be a subtree of 100k+ files.
            let estimatedPatchItems: Int? = {
                guard case .changes(let targets) = replay.outcome else { return nil }
                return WarmStartPlanner.estimatedPatchItemCount(forChangedPaths: targets, cachedTree: cached.tree)
            }()
            let decision = WarmStartPlanner.decide(
                cacheAvailable: true,
                replay: replay.outcome,
                cachedDirectoryCount: cachedDirectoryCount,
                cachedTotalItemCount: cached.tree.count,
                estimatedPatchItems: estimatedPatchItems
            )

            guard self.scanSession.token == attemptToken else { return }

            switch decision {
            case .coldFallback(let reason):
                log.info("Warm start fallback for \(path, privacy: .public): \(reason, privacy: .public)")
                self.beginColdScan(
                    path: path, runPostScanAnalyses: shouldRunPostScanAnalyses, coldFallbackReason: reason,
                    preservedExploration: self.captureExplorationIfPreserving()
                )
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

    /// Snapshots the current selection/treemap-root as an `ExplorationCapture` when a
    /// restored stale view is displayed (`staleViewAsOf != nil`) — nil otherwise, which
    /// makes every downstream "restore position" branch a no-op for the ordinary
    /// (non-restored) scan flow. Callers invoke this immediately before whichever reset
    /// they're about to perform, so it reflects the user's latest interaction with the
    /// stale view right up to that point rather than a snapshot taken earlier in a
    /// multi-second journal replay or rescan.
    private func captureExplorationIfPreserving() -> ExplorationCapture? {
        guard staleViewAsOf != nil, let tree = fileTree else { return nil }
        return ExplorationCapture.capture(
            tree: tree, selectedIndex: selectedNodeIndex, treemapRootIndex: navigation.treemapRootIndex
        )
    }

    /// Records the volume that just finished scanning (warm or cold) so the next launch
    /// can restore it. Best-effort — `UserDefaults` writes don't throw, and a missed
    /// write just means the next launch opens empty, i.e. today's behavior.
    private func persistLastScannedVolume(path: String) {
        defaults.set(path, forKey: Self.lastScannedVolumePathKey)
    }

    // MARK: - Session State (plan 038)

    /// Merges the current selection + treemap-root paths into whatever session snapshot
    /// is already stored for `selectedVolume` — preserving `expandedPaths`, which this
    /// method doesn't touch (`TreeTableView` owns that field; see
    /// `saveExpandedPathsSession(_:)`) — and re-saves. Called from `selectedNodeIndex`'s
    /// `didSet` (AppState.swift) and from `setTreemapRoot` (AppState+Navigation.swift) —
    /// the two AppState-owned actions that change "where you are"; every other treemap
    /// navigation helper (`navigateUp`/`navigateBack`/`navigateForward`/`navigateHome`/
    /// `navigateTo`) goes through `navigation.treemapRootIndex` directly rather than
    /// `setTreemapRoot` and so isn't separately persisted here — same tradeoff 033 already
    /// made for those stacks (dropped by design; see plan's "out of scope"). No-op without
    /// a selected, non-empty tree: nothing meaningful to persist during the brief
    /// empty-tree window at the start of a scan reset.
    func saveSelectionAndRootSession() {
        guard let tree = fileTree, !tree.isEmpty, let root = selectedVolume?.path else { return }
        var snapshot = sessionStore.load(forVolume: root)
            ?? SessionSnapshot(expandedPaths: [], selectedPath: nil, treemapRootPath: nil)
        snapshot.selectedPath = selectedNodeIndex.map { tree.path(at: $0) }
        snapshot.treemapRootPath = tree.path(at: navigation.treemapRootIndex)
        sessionStore.save(snapshot, forVolume: root)
    }

    /// Merges `paths` into the stored session's `expandedPaths` field for
    /// `selectedVolume`, preserving whatever selection/root are already there. Called by
    /// `TreeTableView` (which owns expansion state as view-local `@State`) on every
    /// expand/collapse. No-op without a selected volume.
    func saveExpandedPathsSession(_ paths: Set<String>) {
        guard let root = selectedVolume?.path else { return }
        var snapshot = sessionStore.load(forVolume: root)
            ?? SessionSnapshot(expandedPaths: [], selectedPath: nil, treemapRootPath: nil)
        snapshot.expandedPaths = Array(paths)
        sessionStore.save(snapshot, forVolume: root)
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
        let preservingStaleView = staleViewAsOf != nil
        // Captured before resetForNewScan() below clears selection/navigation — reused
        // to restore position after a successful patch, or handed to the cold fallback
        // if the patch itself can't be trusted (028's unresolved-path/root-level-rescan
        // guard), since that fallback runs after this reset already cleared self's state.
        let preservedExploration = captureExplorationIfPreserving()

        fileTree = tree
        resetForNewScan()
        if !preservingStaleView {
            activeTab = .treeView
        }
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
            beginColdScan(
                path: path, runPostScanAnalyses: shouldRunPostScanAnalyses,
                preservedExploration: preservedExploration
            )
            return
        }

        // A cancelled rescan (plan 042) leaves `tree` valid but only partially patched —
        // whatever finished applying stays applied, the rest didn't. Report that honestly
        // instead of the "success" bookkeeping below: no cache write-back under the new
        // event id (it would wrongly claim every target was applied), no completion
        // summary implying a finished refresh.
        guard !report.wasCancelled else {
            log.info("Warm start cancelled mid-patch for \(path, privacy: .public); tree reflects a partial refresh")
            scanSession.markFinished()
            computeExtensionStats()
            scanProgress.publishCounters(forceLayoutRevision: true)
            scanProgress.isScanning = false
            scanProgress.isCancelled = true
            scanProgress.scanComplete = true
            return
        }

        scanSession.markFinished()
        persistLastScannedVolume(path: path)
        if preservingStaleView {
            selectedNodeIndex = preservedExploration?.selectedPath.flatMap {
                ExplorationCapture.resolveOrAncestor($0, tree: tree)
            }
            let resolvedRoot = preservedExploration?.treemapRootPath.flatMap {
                ExplorationCapture.resolveOrAncestor($0, tree: tree)
            } ?? 0
            setTreemapRoot(resolvedRoot, recordHistory: false)
        } else {
            setTreemapRoot(0, recordHistory: false)
        }
        computeExtensionStats()
        scanProgress.publishCounters(forceLayoutRevision: true)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let summary = ScanSummaryComposer.warm(foldersRefreshed: report.rescannedRoots.count, seconds: elapsed)
        scanProgress.isScanning = false
        scanProgress.scanComplete = true
        scanProgress.currentPath = summary
        lastScanSummary = summary
        staleViewAsOf = nil

        do {
            try TreeCache.save(tree: tree, lastEventId: newEventId)
        } catch {
            log.error("TreeCache save failed after warm start: \(error.localizedDescription, privacy: .public)")
        }

        if shouldRunPostScanAnalyses {
            await runPostScanAnalyses(tree: tree, volumePath: path, token: token)
        }
    }

    /// The app's default materialization strategy for a cold, whole-volume scan (plan
    /// 039): build the shared tree live (immediate) so the treemap/tree table fill in as
    /// the scan runs, instead of appearing all at once at the end (deferred). This
    /// inverts `FileScanner.init`'s own default, which favors deferred for callers (the
    /// CLI) that don't materialize incrementally into a displayed tree. `DIRWIZ_DEFER_TREE`
    /// still wins when set explicitly, in both directions: `0` is immediate (matching the
    /// app default, so it's a no-op here) and anything else forces deferred — the instant
    /// rollback for A/B debugging if immediate ever misbehaves on an exotic volume.
    private static var appDefersTreeMaterialization: Bool {
        guard let envValue = ProcessInfo.processInfo.environment["DIRWIZ_DEFER_TREE"] else { return false }
        return envValue != "0"
    }

    /// Today's full enumeration — byte-for-byte the pre-warm-start flow. Reused both as
    /// the direct path (no cache, or "Full Rescan") and as the fallback whenever a warm
    /// attempt can't be trusted. `coldFallbackReason` is only set when this cold scan
    /// replaces a warm attempt the planner declined — surfaced in the completion summary
    /// so the fallback is legible instead of only a log line.
    private func beginColdScan(
        path: String,
        runPostScanAnalyses shouldRunPostScanAnalyses: Bool,
        coldFallbackReason: String? = nil,
        preservedExploration: ExplorationCapture? = nil
    ) {
        // Captured before the scan starts: any filesystem activity on this volume from
        // here on is exactly what the *next* warm start needs to replay.
        let eventIdAtScanStart = FSEventsJournal.currentEventId()

        let scanner = FileScanner(
            computeBundleSizes: false,
            deferTreeMaterialization: Self.appDefersTreeMaterialization
        )
        let tree = FileTree()
        let preservingStaleView = staleViewAsOf != nil

        if preservingStaleView {
            // A restored view is on screen — build into `tree` (a detached instance) and
            // keep displaying the stale `fileTree`/selection/navigation untouched until
            // the scan finishes, so it stays fully browsable while this runs behind it.
            scanSession.invalidate()
            scanProgress = ScanProgress()
        } else {
            fileTree = tree
            resetForNewScan()
            activeTab = .treeView
        }
        scanSession.markStarted(scanner: scanner)
        let token = scanToken

        Task {
            await scanner.scan(path: path, progress: scanProgress, tree: tree)
            let handoff = await MainActor.run { () -> (scanCompleted: Bool, sizingTask: Task<Void, Never>?) in
                guard self.scanToken == token else { return (false, nil) }
                self.scanSession.markFinished()
                // Cancellation mid-preserving-cold: leave the stale tree, selection, and
                // badge exactly as they were — nothing newer replaces them, so the badge
                // stays honest without this branch needing to say anything further.
                guard !self.scanProgress.isCancelled else { return (false, nil) }

                self.persistLastScannedVolume(path: path)
                if preservingStaleView {
                    self.fileTree = tree
                    self.resetTreeDerivedState()
                    self.selectedNodeIndex = preservedExploration?.selectedPath.flatMap {
                        ExplorationCapture.resolveOrAncestor($0, tree: tree)
                    }
                    let resolvedRoot = preservedExploration?.treemapRootPath.flatMap {
                        ExplorationCapture.resolveOrAncestor($0, tree: tree)
                    } ?? 0
                    self.setTreemapRoot(resolvedRoot, recordHistory: false)
                    self.scanProgress.publishCounters(forceLayoutRevision: true)
                    self.staleViewAsOf = nil
                } else {
                    self.setTreemapRoot(0, recordHistory: false)
                }
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

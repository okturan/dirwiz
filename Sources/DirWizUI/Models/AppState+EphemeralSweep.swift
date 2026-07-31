import DirWizCore
import Foundation
import OSLog

private let ephemeralSweepLog = Logger(
    subsystem: "com.dirwiz",
    category: "EphemeralSweep"
)

extension AppState {
    /// Quiet, informational copy for the same sidebar surfaces that already explain
    /// restored/stale scans. Ephemeral staleness is not a permission failure and must
    /// never increment the skipped-directory counters.
    public var ephemeralStaleStatusText: String? {
        guard !pendingEphemeralRoots.isEmpty else { return nil }
        if isEphemeralSweepRunning {
            return "Updating temporary folders…"
        }
        switch ephemeralSweepDecision {
        case .sweep:
            return "Temporary folders are waiting to update."
        case .wait(let reason):
            return "Temporary folders are shown from the last sweep. \(reason)"
        }
    }

    /// Records the complete atomic checkpoint currently on disk. A checkpoint is also a
    /// fully-fresh ephemeral baseline when no work is pending, so it is the scheduler's
    /// last-sweep time even if the write followed an interactive-only live patch.
    func recordPersistedCacheCheckpoint(
        eventId: UInt64,
        savedAt: Date
    ) {
        persistedCacheEventId = eventId
        persistedCacheSavedAt = savedAt
        guard pendingEphemeralRoots.isEmpty else { return }
        lastEphemeralSweepAt = savedAt.timeIntervalSinceReferenceDate
    }

    /// Starts or extends one held horizon. The on-disk cache is deliberately left alone;
    /// the eventual sweep replays again from this exact event id so changes that land
    /// between the first warm replay and live-monitor startup cannot be missed.
    func registerPendingEphemeralRoots(
        _ roots: [String],
        checkpointEventId: UInt64? = nil,
        checkpointSavedAt: Date? = nil
    ) {
        guard !roots.isEmpty else { return }

        if pendingEphemeralRoots.isEmpty {
            let eventId = checkpointEventId ?? persistedCacheEventId
            let savedAt = checkpointSavedAt ?? persistedCacheSavedAt
            ephemeralSweepHorizonEventId = eventId
            ephemeralSweepHorizonStartedAt =
                savedAt?.timeIntervalSinceReferenceDate
            if lastEphemeralSweepAt == nil {
                lastEphemeralSweepAt =
                    savedAt?.timeIntervalSinceReferenceDate
            }
            staleViewAsOf = staleViewAsOf ?? savedAt ?? Date()
        }

        var seen = Set(pendingEphemeralRoots)
        for root in roots where seen.insert(root).inserted {
            pendingEphemeralRoots.append(root)
        }
        refreshEphemeralSweepDecision()
    }

    /// Synchronous verdict refresh for UI and tests. Scheduling callers invoke the async
    /// counterpart below so `.sweep` acts immediately.
    public func refreshEphemeralSweepDecision() {
        ephemeralSweepDecision = EphemeralSweepPolicy.decide(
            currentEphemeralSweepInput(),
            configuration: ephemeralSweepConfiguration
        )
    }

    /// Re-evaluated on every living-view tick and after navigation. A wait verdict is
    /// presentation only; no latch suppresses a later eligible tick.
    public func evaluateEphemeralSweepAndApply() async {
        guard !isEphemeralSweepRunning else { return }
        let decision = EphemeralSweepPolicy.decide(
            currentEphemeralSweepInput(),
            configuration: ephemeralSweepConfiguration
        )
        ephemeralSweepDecision = decision
        guard decision == .sweep else { return }
        await performEphemeralSweep()
    }

    /// Navigation freshness has value only when the requested subtree overlaps pending
    /// ephemeral work. The request stays sticky if a scan/heavy task/diff guard is active;
    /// the next coordinator tick re-evaluates it.
    func requestEphemeralSweepForNavigation(to path: String) {
        guard ephemeralPaths.contains(path),
              pendingEphemeralRoots.contains(where: {
                  Self.pathsOverlap($0, path)
              }) else {
            return
        }
        ephemeralNavigationSweepRequested = true
        refreshEphemeralSweepDecision()
        Task { @MainActor [weak self] in
            await self?.evaluateEphemeralSweepAndApply()
        }
    }

    private func currentEphemeralSweepInput() -> EphemeralSweepPolicy.Input {
        let now = ephemeralSweepClock()
        var activeGuards = Set<EphemeralSweepPolicy.ActiveGuard>()
        if scanProgress.isScanning {
            activeGuards.insert(.scan)
        }
        if temporalDiff.isTemporalDiffEnabled {
            activeGuards.insert(.temporalDiff)
        }
        if activeHeavyTask != nil {
            activeGuards.insert(.heavyTask)
        }

        let horizonAge = ephemeralSweepHorizonStartedAt.map {
            max(0, now - $0)
        }
        return EphemeralSweepPolicy.Input(
            lastSweepAt: lastEphemeralSweepAt,
            now: now,
            pendingEphemeralRoots: pendingEphemeralRoots,
            activeGuards: activeGuards,
            horizonAge: horizonAge,
            navigationRequested: ephemeralNavigationSweepRequested
        )
    }

    private func performEphemeralSweep() async {
        guard !pendingEphemeralRoots.isEmpty,
              let tree = fileTree,
              let rootPath = selectedVolume?.path else {
            refreshEphemeralSweepDecision()
            return
        }

        // An unknown held event id cannot be made exact by guessing. The pure policy
        // deliberately selects `.sweep` for an unknown horizon; the acting layer turns
        // that into an honest cold fallback before any newer cache id can be written.
        guard let heldEventId = ephemeralSweepHorizonEventId else {
            startColdFallbackFromEphemeralSweep(
                reason: "temporary-folder cache horizon is unavailable"
            )
            return
        }

        isEphemeralSweepRunning = true
        scanProgress.isCancelled = false
        refreshEphemeralSweepDecision()
        let token = scanToken
        let replayStartedAt = ContinuousClock().now
        let replay = await FSEventsJournal.replay(
            root: rootPath,
            since: heldEventId
        )
        let replaySeconds = Self.seconds(
            ContinuousClock().now - replayStartedAt
        )

        guard scanToken == token else {
            isEphemeralSweepRunning = false
            return
        }

        let estimatedPatchItems: Int? = {
            guard case .changes(let targets) = replay.outcome else {
                return nil
            }
            return WarmStartPlanner.estimatedPatchItemCount(
                forChangedPaths: targets,
                cachedTree: tree
            )
        }()
        let cachedDirectoryCount = tree.nodesSnapshot().reduce(0) {
            $0 + ($1.isDirectory ? 1 : 0)
        }
        let plannerDecision = WarmStartPlanner.decide(
            cacheAvailable: true,
            replay: replay.outcome,
            cachedDirectoryCount: cachedDirectoryCount,
            cachedTotalItemCount: tree.count,
            estimatedPatchItems: estimatedPatchItems
        )

        let replayTargets: [String]
        switch plannerDecision {
        case .coldFallback(let reason):
            isEphemeralSweepRunning = false
            startColdFallbackFromEphemeralSweep(
                reason: "held temporary-folder replay \(reason)"
            )
            return
        case .warm(let targets):
            replayTargets = targets
        }

        // Replaying from the held checkpoint covers interactive changes too. Reapplying
        // them is intentionally idempotent and is what makes the new event id safe to
        // persist. The remembered roots are a defensive union for coalesced/deleted event
        // shapes; FileScanner performs its normal resolve/collapse pass.
        var requestedTargets = replayTargets
        var seenTargets = Set(requestedTargets)
        for path in pendingEphemeralRoots
            where seenTargets.insert(path).inserted {
            requestedTargets.append(path)
        }

        let exploration = ExplorationCapture.capture(
            tree: tree,
            selectedIndex: selectedNodeIndex,
            treemapRootIndex: navigation.treemapRootIndex
        )
        warmPatchExploration = exploration
        warmPatchExplorationToken = token
        let scanner = warmPatchScannerFactory()
        ephemeralSweepScanner = scanner
        // The delayed sweep mutates the same displayed cached tree as a warm patch.
        // A superseding scan must therefore detach that tree before cancellation can
        // race with the transactional commit. Keep ownership token-scoped so an older
        // sweep can never clear a newer scan's mutation guard.
        warmPatchMutatesDisplayedTree = true
        defer {
            if scanToken == token {
                warmPatchMutatesDisplayedTree = false
                isWarmPatchCommitInProgress = false
                ephemeralSweepScanner = nil
                if warmPatchExplorationToken == token {
                    warmPatchExploration = nil
                    warmPatchExplorationToken = nil
                }
            }
        }
        let report = await scanner.rescanSubtrees(
            requestedTargets,
            tree: tree,
            progress: ScanProgress(),
            options: .trailing,
            onWillCommit: { [weak self] in
                guard let self, self.scanToken == token else { return }
                self.isWarmPatchCommitInProgress = true
            }
        )

        if scanToken == token {
            isWarmPatchCommitInProgress = false
        }
        guard scanToken == token else {
            isEphemeralSweepRunning = false
            return
        }
        let latestExploration = warmPatchExploration
        warmPatchExploration = nil
        warmPatchExplorationToken = nil

        // This is the delayed equivalent of the old trailing tier's mandatory second
        // publication boundary. A zero-change successful splice still invalidates because
        // it passed through the same index-renumbering contract.
        if report.metrics.appliedRootCount > 0 {
            invalidateAfterTreeMutation(restoring: latestExploration)
            computeExtensionStats()
        }

        if !report.unresolvedPaths.isEmpty
            || report.rescannedRoots.contains(rootPath) {
            isEphemeralSweepRunning = false
            let detail = !report.unresolvedPaths.isEmpty
                ? "couldn't resolve \(report.unresolvedPaths.count) changed paths"
                : "a changed path resolved to the scan root"
            startColdFallbackFromEphemeralSweep(reason: detail)
            return
        }
        guard !report.wasCancelled else {
            isEphemeralSweepRunning = false
            scanProgress.isCancelled = true
            if report.metrics.appliedRootCount == 0 {
                // A warm restore resets derived state before either tier starts. If this
                // forced sweep was cancelled before its first splice, no canonical
                // invalidation rebuilt that state, so restore the path-keyed analyses
                // without pretending the stale temporary subtree became fresh.
                computeExtensionStats()
                refreshHardlinkGroups()
                scanProgress.publishCounters(forceLayoutRevision: true)
            }
            refreshEphemeralSweepDecision()
            return
        }
        if report.metrics.appliedRootCount == 0 {
            invalidateAfterTreeMutation(restoring: latestExploration)
            computeExtensionStats()
        }

        guard let persistableEventId =
                WarmPatchCacheHorizon.eventIdForPersistence(
                    replayedThrough: replay.newEventId,
                    deferredTargetCount: 0
                ) else {
            assertionFailure("successful ephemeral sweep did not release cache horizon")
            isEphemeralSweepRunning = false
            refreshEphemeralSweepDecision()
            return
        }

        // Save first, then clear the hold. If persistence fails, the old checkpoint
        // remains valid and the in-memory sweep is simply retried idempotently later.
        let checkpointDate = Date()
        do {
            try TreeCache.save(
                tree: tree,
                lastEventId: persistableEventId
            )
        } catch {
            ephemeralSweepLog.error(
                "TreeCache save failed after ephemeral sweep: \(error.localizedDescription, privacy: .public)"
            )
            isEphemeralSweepRunning = false
            refreshEphemeralSweepDecision()
            return
        }

        let stagedItems = report.metrics.rootStaging.reduce(0) {
            $0 + $1.actualStagedItemCount
        }
        ephemeralSweepLog.info(
            "Completed throttled sweep: roots=\(report.rescannedRoots.count), staged_items=\(stagedItems), replay_seconds=\(replaySeconds, format: .fixed(precision: 3)), sweep_seconds=\(report.metrics.totalSeconds, format: .fixed(precision: 3))"
        )

        pendingEphemeralRoots = []
        ephemeralSweepHorizonEventId = nil
        ephemeralSweepHorizonStartedAt = nil
        ephemeralNavigationSweepRequested = false
        staleViewAsOf = nil
        recordPersistedCacheCheckpoint(
            eventId: persistableEventId,
            savedAt: checkpointDate
        )
        isEphemeralSweepRunning = false
        lastScanSummary = "Updated temporary folders"
        autoCheckpointIfDue()
        refreshEphemeralSweepDecision()
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
            || lhs.hasPrefix(rhs.hasSuffix("/") ? rhs : rhs + "/")
            || rhs.hasPrefix(lhs.hasSuffix("/") ? lhs : lhs + "/")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds)
                / 1_000_000_000_000_000_000
    }
}

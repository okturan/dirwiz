import Darwin
import Foundation
import Testing
@testable import DirWizCore
@testable import DirWizUI

/// Deliberately stricter than the ordinary heavy-benchmark gate: a real-volume scan can
/// take minutes on a slow or very full disk and must never happen merely because someone
/// ran `swift test`. The exact opt-in is intentionally named in both the code and output.
private let runRealVolumeWarmStartBenchmark =
    ProcessInfo.processInfo.environment["DIRWIZ_REAL_VOLUME_BENCH"] == "1"

/// Optional diagnostic mode layered on top of the already explicit real-volume
/// benchmark opt-in. A warm decision gets one excluded control/tiered warm-up, then four
/// timed crossover pairs from independent decodes of the same pre-patch scratch cache,
/// using the exact target list returned by that one journal/planner decision. This is
/// deliberately not implied by
/// `DIRWIZ_REAL_VOLUME_BENCH`: it makes an already expensive benchmark substantially
/// heavier.
private let runRealVolumeWarmStartDiagnostics =
    ProcessInfo.processInfo.environment["DIRWIZ_REAL_VOLUME_DIAGNOSTIC"] == "1"

/// Keeps the ordinary three-refresh benchmark unchanged while making the heavier
/// diagnostic mode honest about whether it actually observed a patchable workload.
private enum RealVolumeDiagnosticPolicy {
    static let ordinaryRefreshAttemptCount = 3
    static let requiredWarmWorkloadCount = 3
    static let samplesPerWarmWorkload = 4

    /// Eight attempts give diagnostic mode five additional independent journal windows
    /// beyond the ordinary three. A prior three-attempt run produced two warm decisions,
    /// while another produced none, so eight improves the chance of collecting three
    /// without pretending ambient filesystem churn can be forced. At the observed
    /// ~30-second upper end for a cold fallback, the bounded worst case is about four
    /// minutes - substantial but finite, and well inside this suite's 30-minute timeout.
    static let diagnosticRefreshAttemptLimit = 8

    static func refreshAttemptLimit(diagnosticEnabled: Bool) -> Int {
        diagnosticEnabled
            ? diagnosticRefreshAttemptLimit
            : ordinaryRefreshAttemptCount
    }

    static func shouldCollect(
        diagnosticEnabled: Bool,
        interactiveTargetCount: Int,
        temporaryTargetCount: Int
    ) -> Bool {
        diagnosticEnabled
            && interactiveTargetCount > 0
            && temporaryTargetCount > 0
    }

    static func hasRequiredWarmWorkloads(_ completedWorkloadCount: Int) -> Bool {
        completedWorkloadCount >= requiredWarmWorkloadCount
    }
}

private struct RealVolumeDiagnosticTimingPair {
    let controlDuration: Double
    let interactiveDuration: Double
    let controlStagedItems: Int
    let tieredStagedItems: Int
    let interactiveStagedItems: Int
    let controlRanFirst: Bool

    var relativeImprovement: Double {
        guard controlDuration > 0 else { return -.infinity }
        return (controlDuration - interactiveDuration) / controlDuration
    }

    var matchedStagedItemDeltaFraction: Double {
        let denominator = max(controlStagedItems, tieredStagedItems, 1)
        return Double(abs(controlStagedItems - tieredStagedItems))
            / Double(denominator)
    }
}

private struct RealVolumeDiagnosticBalancedEffect {
    let relativeImprovement: Double
    let controlFirstMeanLogRatio: Double
    let tieredFirstMeanLogRatio: Double

    var orderBlockLogRatioDelta: Double {
        abs(controlFirstMeanLogRatio - tieredFirstMeanLogRatio)
    }
}

/// Keeps the timing gate paired and workload-comparable. Control and tiered times from
/// different samples must never be combined into a synthetic ratio: filesystem and cache
/// state can drift between repeats even when every repeat starts from the same persisted
/// tree.
private enum RealVolumeDiagnosticTimingPolicy {
    static let materialImprovementFloor = 0.15
    static let stagedWorkTolerance = 0.05
    /// A reciprocal order block whose interactive/control ratio differs by more than 2x
    /// is not identifying a schedule effect; it is identifying cache/load position.
    static let maximumOrderBlockLogRatioDelta = log(2.0)

    static func relativeSpread(_ values: [Int]) -> Double {
        guard let minimum = values.min(),
              let maximum = values.max(),
              maximum > 0 else {
            return values.isEmpty ? .infinity : 0
        }
        return Double(maximum - minimum) / Double(maximum)
    }

    static func isComparable(
        _ pairs: [RealVolumeDiagnosticTimingPair],
        expectedCount: Int
    ) -> Bool {
        expectedCount > 0
            && expectedCount.isMultiple(of: 2)
            && pairs.count == expectedCount
            && pairs.filter(\.controlRanFirst).count == expectedCount / 2
            && pairs.filter { !$0.controlRanFirst }.count == expectedCount / 2
            && pairs.allSatisfy {
                $0.controlDuration > 0
                    && $0.interactiveDuration > 0
                    && $0.interactiveStagedItems > 0
                    && $0.matchedStagedItemDeltaFraction <= stagedWorkTolerance
            }
            && relativeSpread(pairs.map(\.controlStagedItems))
                <= stagedWorkTolerance
            && relativeSpread(pairs.map(\.tieredStagedItems))
                <= stagedWorkTolerance
    }

    static func medianRelativeImprovement(
        _ pairs: [RealVolumeDiagnosticTimingPair]
    ) -> Double? {
        guard !pairs.isEmpty else { return nil }
        let ordered = pairs.map(\.relativeImprovement).sorted()
        return ordered[ordered.count / 2]
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    /// Equal-weight the two reciprocal run orders in log-ratio space. If first-vs-second
    /// cache warmth is multiplicative, the nuisance factor cancels when the order blocks
    /// are averaged; converting back yields the schedule's relative time improvement.
    static func balancedEffect(
        _ pairs: [RealVolumeDiagnosticTimingPair]
    ) -> RealVolumeDiagnosticBalancedEffect? {
        let controlFirst = pairs.filter(\.controlRanFirst)
        let tieredFirst = pairs.filter { !$0.controlRanFirst }
        guard !controlFirst.isEmpty,
              controlFirst.count == tieredFirst.count,
              pairs.allSatisfy({
                  $0.controlDuration > 0 && $0.interactiveDuration > 0
              }) else {
            return nil
        }

        func meanLogRatio(
            _ block: [RealVolumeDiagnosticTimingPair]
        ) -> Double {
            block.reduce(0) {
                $0 + log($1.interactiveDuration / $1.controlDuration)
            } / Double(block.count)
        }

        let controlFirstMean = meanLogRatio(controlFirst)
        let tieredFirstMean = meanLogRatio(tieredFirst)
        let balancedLogRatio =
            (controlFirstMean + tieredFirstMean) / 2
        return RealVolumeDiagnosticBalancedEffect(
            relativeImprovement: 1 - exp(balancedLogRatio),
            controlFirstMeanLogRatio: controlFirstMean,
            tieredFirstMeanLogRatio: tieredFirstMean
        )
    }
}

@Suite("Real-volume diagnostic attempt policy")
struct RealVolumeDiagnosticAttemptPolicyTests {
    @Test("Ordinary mode stays at three attempts and diagnostic mode is bounded")
    func attemptLimits() {
        #expect(
            RealVolumeDiagnosticPolicy.refreshAttemptLimit(
                diagnosticEnabled: false
            ) == 3
        )
        #expect(
            RealVolumeDiagnosticPolicy.refreshAttemptLimit(
                diagnosticEnabled: true
            ) == 8
        )
    }

    @Test("Only decisions with both tiers count, and three workloads finish the gate")
    func collectionAndCompletion() {
        #expect(
            !RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: false,
                interactiveTargetCount: 6,
                temporaryTargetCount: 6
            )
        )
        #expect(
            !RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: true,
                interactiveTargetCount: 0,
                temporaryTargetCount: 6
            )
        )
        #expect(
            !RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: true,
                interactiveTargetCount: 6,
                temporaryTargetCount: 0
            )
        )
        #expect(
            RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: true,
                interactiveTargetCount: 1,
                temporaryTargetCount: 1
            )
        )
        #expect(!RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(2))
        #expect(RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(3))
    }

    @Test("Timing gate uses matched-pair improvements, not independent duration medians")
    func pairedMedian() {
        let pairs = [
            RealVolumeDiagnosticTimingPair(
                controlDuration: 100,
                interactiveDuration: 80,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: true
            ),
            RealVolumeDiagnosticTimingPair(
                controlDuration: 10,
                interactiveDuration: 1,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: false
            ),
            RealVolumeDiagnosticTimingPair(
                controlDuration: 10,
                interactiveDuration: 9,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: true
            ),
        ]

        // Paired improvements are 20%, 90%, and 10%, so the median is 20%.
        // Independently dividing the duration medians (10 and 9) would invent 10%.
        #expect(
            RealVolumeDiagnosticTimingPolicy.medianRelativeImprovement(pairs)
                == 0.2
        )
    }

    @Test("Timing gate refuses all-ephemeral and materially drifting workloads")
    func workloadComparability() {
        let comparable = (0..<4).map { sample in
            RealVolumeDiagnosticTimingPair(
                controlDuration: 2,
                interactiveDuration: 1,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 400,
                controlRanFirst: sample < 2
            )
        }
        #expect(
            RealVolumeDiagnosticTimingPolicy.isComparable(
                comparable,
                expectedCount: 4
            )
        )
        #expect(
            !RealVolumeDiagnosticTimingPolicy.isComparable(
                Array(comparable.prefix(3)),
                expectedCount: 3
            )
        )

        var allEphemeral = comparable
        allEphemeral[1] = RealVolumeDiagnosticTimingPair(
            controlDuration: 2,
            interactiveDuration: 0,
            controlStagedItems: 1_000,
            tieredStagedItems: 1_000,
            interactiveStagedItems: 0,
            controlRanFirst: true
        )
        #expect(
            !RealVolumeDiagnosticTimingPolicy.isComparable(
                allEphemeral,
                expectedCount: 4
            )
        )

        var drifting = comparable
        drifting[2] = RealVolumeDiagnosticTimingPair(
            controlDuration: 2,
            interactiveDuration: 1,
            controlStagedItems: 1_200,
            tieredStagedItems: 1_200,
            interactiveStagedItems: 480,
            controlRanFirst: false
        )
        #expect(
            !RealVolumeDiagnosticTimingPolicy.isComparable(
                drifting,
                expectedCount: 4
            )
        )
    }

    @Test("Balanced crossover cancels multiplicative first-run cache position")
    func balancedCrossover() throws {
        let pairs = [
            RealVolumeDiagnosticTimingPair(
                controlDuration: 10,
                interactiveDuration: 6,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: true
            ),
            RealVolumeDiagnosticTimingPair(
                controlDuration: 10,
                interactiveDuration: 6,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: true
            ),
            RealVolumeDiagnosticTimingPair(
                controlDuration: 7.5,
                interactiveDuration: 8,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: false
            ),
            RealVolumeDiagnosticTimingPair(
                controlDuration: 7.5,
                interactiveDuration: 8,
                controlStagedItems: 1_000,
                tieredStagedItems: 1_000,
                interactiveStagedItems: 500,
                controlRanFirst: false
            ),
        ]

        let effect = try #require(
            RealVolumeDiagnosticTimingPolicy.balancedEffect(pairs)
        )
        #expect(abs(effect.relativeImprovement - 0.2) < 0.000_001)
        #expect(
            effect.orderBlockLogRatioDelta
                < RealVolumeDiagnosticTimingPolicy
                    .maximumOrderBlockLogRatioDelta
        )
    }
}

/// One root's cached-tree estimate compared with the Phase A work that was actually
/// staged. The sign convention is deliberate: a negative error means the cached estimate
/// undershot the live filesystem work, which is the dangerous direction for the item gate.
private struct RootStagingEstimateComparison: Equatable {
    let path: String
    let estimatedItemCount: Int?
    let actualStagedItemCount: Int

    var estimateMinusActualItemCount: Int? {
        estimatedItemCount.map { $0 - actualStagedItemCount }
    }

    var estimateErrorPercentOfActual: Double? {
        guard actualStagedItemCount > 0,
              let estimateMinusActualItemCount else {
            return nil
        }
        return Double(estimateMinusActualItemCount) / Double(actualStagedItemCount) * 100
    }
}

private struct RootStagingDistribution {
    let rootsByActualItemCount: [RootStagingEstimateComparison]
    let totalActualStagedItemCount: Int

    var totalEstimatedItemCount: Int? {
        var total = 0
        for root in rootsByActualItemCount {
            guard let estimate = root.estimatedItemCount else { return nil }
            let sum = total.addingReportingOverflow(estimate)
            total = sum.overflow ? Int.max : sum.partialValue
        }
        return total
    }

    var topRootShare: Double {
        guard totalActualStagedItemCount > 0,
              let topRoot = rootsByActualItemCount.first else {
            return 0
        }
        return Double(topRoot.actualStagedItemCount)
            / Double(totalActualStagedItemCount)
    }

    /// Task 1.3 says "over half", not half-or-more. Keep the decision exact so two
    /// equally sized roots do not accidentally trigger the diagnostic STOP.
    var singleRootOverHalf: Bool {
        topRootShare > 0.5
    }
}

private func rootStagingDistribution(
    _ roots: [RootStagingEstimateComparison]
) -> RootStagingDistribution {
    let ordered = roots.sorted {
        if $0.actualStagedItemCount != $1.actualStagedItemCount {
            return $0.actualStagedItemCount > $1.actualStagedItemCount
        }
        return $0.path < $1.path
    }
    return RootStagingDistribution(
        rootsByActualItemCount: ordered,
        totalActualStagedItemCount: ordered.reduce(0) {
            $0 + $1.actualStagedItemCount
        }
    )
}

/// Attributes planner-time estimates to the actual root Phase A staged. A changed path
/// can disappear from the cached tree and resolve upward to its nearest surviving parent;
/// looking up the parent's path would then report "unavailable" (or the whole parent's
/// cached size) instead of preserving the planner's 32-item unresolved estimate.
private func attributedCachedEstimate(
    contributingRequestedPaths: [String],
    estimatedItemsByRequestedPath: [String: Int]
) -> Int? {
    guard !contributingRequestedPaths.isEmpty else { return nil }

    var total = 0
    for requestedPath in contributingRequestedPaths {
        guard let estimate = estimatedItemsByRequestedPath[requestedPath] else {
            return nil
        }
        let sum = total.addingReportingOverflow(estimate)
        total = sum.overflow ? Int.max : sum.partialValue
    }
    return total
}

@Suite("Real-volume root staging distribution")
struct RealVolumeRootStagingDistributionTests {
    @Test("Sorts by actual work and triggers only when one root is over half")
    func dominantRootDecision() {
        let dominant = rootStagingDistribution([
            RootStagingEstimateComparison(
                path: "/small",
                estimatedItemCount: 25,
                actualStagedItemCount: 20
            ),
            RootStagingEstimateComparison(
                path: "/large",
                estimatedItemCount: 40,
                actualStagedItemCount: 80
            ),
        ])

        #expect(dominant.rootsByActualItemCount.map(\.path) == ["/large", "/small"])
        #expect(dominant.totalActualStagedItemCount == 100)
        #expect(dominant.totalEstimatedItemCount == 65)
        #expect(dominant.topRootShare == 0.8)
        #expect(dominant.singleRootOverHalf)
        #expect(
            dominant.rootsByActualItemCount[0].estimateMinusActualItemCount == -40
        )
        #expect(
            dominant.rootsByActualItemCount[0].estimateErrorPercentOfActual == -50
        )

        let tied = rootStagingDistribution([
            RootStagingEstimateComparison(
                path: "/a",
                estimatedItemCount: 50,
                actualStagedItemCount: 50
            ),
            RootStagingEstimateComparison(
                path: "/b",
                estimatedItemCount: 50,
                actualStagedItemCount: 50
            ),
        ])
        #expect(tied.topRootShare == 0.5)
        #expect(!tied.singleRootOverHalf)

        let missingEstimate = rootStagingDistribution([
            RootStagingEstimateComparison(
                path: "/resolved-upward",
                estimatedItemCount: nil,
                actualStagedItemCount: 90
            ),
            RootStagingEstimateComparison(
                path: "/known",
                estimatedItemCount: 10,
                actualStagedItemCount: 10
            ),
        ])
        #expect(missingEstimate.totalActualStagedItemCount == 100)
        #expect(missingEstimate.totalEstimatedItemCount == nil)
        #expect(missingEstimate.topRootShare == 0.9)
        #expect(missingEstimate.singleRootOverHalf)
    }

    @Test("Resolved-upward roots keep and sum their original requested-path estimates")
    func resolvedUpwardEstimateAttribution() {
        let estimates = [
            "/cached/parent/new-a": 32,
            "/cached/parent/new-b": 32,
        ]

        #expect(
            attributedCachedEstimate(
                contributingRequestedPaths: ["/cached/parent/new-a"],
                estimatedItemsByRequestedPath: estimates
            ) == 32
        )
        #expect(
            attributedCachedEstimate(
                contributingRequestedPaths: [
                    "/cached/parent/new-a",
                    "/cached/parent/new-b",
                ],
                estimatedItemsByRequestedPath: estimates
            ) == 64
        )
        // The actual staged root is the surviving parent, but its path is deliberately
        // NOT a key. Attribution must use the original requested paths, never substitute
        // the resolved parent and silently lose the planner's estimate.
        #expect(
            attributedCachedEstimate(
                contributingRequestedPaths: ["/cached/parent"],
                estimatedItemsByRequestedPath: estimates
            ) == nil
        )
    }
}

/// This benchmark mutates the process-global `DIRWIZ_APP_SUPPORT_DIR`, so it must live
/// beneath `AppSupportEnvSuites` rather than the otherwise usual
/// `PerformanceSensitiveSuites`. Its stricter explicit opt-in keeps it out of both normal
/// local runs and CI, while the serialized parent prevents another App Support test from
/// observing this benchmark's scratch cache directory.
extension AppSupportEnvSuites {

    @Suite(
        "Real-volume Warm Start Benchmark",
        .serialized,
        .enabled(
            if: runRealVolumeWarmStartBenchmark,
            "Set DIRWIZ_REAL_VOLUME_BENCH=1 to run the read-only real-volume benchmark"
        )
    )
    struct RealVolumeWarmStartBenchmarkTests {
        private static let diagnosticPatchSampleCount =
            RealVolumeDiagnosticPolicy.samplesPerWarmWorkload
        private static let tieredPublicationDefaultsSuite =
            "DirWizTests.RealVolumeTieredPublication"
        private static let controlPublicationDefaultsSuite =
            "DirWizTests.RealVolumeControlPublication"
        private static let machTimebase: (numerator: UInt32, denominator: UInt32) = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return (info.numer, max(1, info.denom))
        }()

        private struct MemorySample {
            let residentBytes: UInt64
            let physicalFootprintBytes: UInt64
            let peakResidentBytes: UInt64
        }

        private struct ProcessResourceSample {
            /// Mach absolute-time ticks accumulated by this process.
            let userCPUTime: UInt64
            /// Mach absolute-time ticks accumulated by this process.
            let systemCPUTime: UInt64
            let diskBytesRead: UInt64
            let diskBytesWritten: UInt64
            let instructions: UInt64
            let cycles: UInt64
            let residentBytes: UInt64
            let physicalFootprintBytes: UInt64
        }

        private struct TreeStats: Equatable {
            let items: Int
            let directories: Int
            let files: Int
            let allocatedBytes: UInt64
        }

        private struct TieredPatchResult {
            let interactiveReport: SubtreeRescanReport
            let trailingReport: SubtreeRescanReport
            let interactiveDuration: Double
            let trailingDuration: Double
            let temporaryRoot: String?
            let finalStats: TreeStats

            var totalDuration: Double {
                interactiveDuration + trailingDuration
            }

            var reports: [SubtreeRescanReport] {
                [interactiveReport, trailingReport]
            }

            var combinedRootStaging: [SubtreeRescanMetrics.RootStaging] {
                reports.flatMap(\.metrics.rootStaging)
            }

            var interactiveStagedItems: Int {
                interactiveReport.metrics.rootStaging.reduce(0) {
                    $0 + $1.actualStagedItemCount
                }
            }

            var trailingStagedItems: Int {
                trailingReport.metrics.rootStaging.reduce(0) {
                    $0 + $1.actualStagedItemCount
                }
            }

            var totalStagedItems: Int {
                interactiveStagedItems + trailingStagedItems
            }

            private func temporaryRootStagedItems(
                in report: SubtreeRescanReport
            ) -> Int {
                guard let temporaryRoot else { return 0 }
                return report.metrics.rootStaging.reduce(0) { total, root in
                    let isTemporary =
                        root.path == temporaryRoot
                        || root.path.hasPrefix(temporaryRoot + "/")
                    return total + (isTemporary ? root.actualStagedItemCount : 0)
                }
            }

            var interactiveTemporaryRootStagedItems: Int {
                temporaryRootStagedItems(in: interactiveReport)
            }

            var trailingTemporaryRootStagedItems: Int {
                temporaryRootStagedItems(in: trailingReport)
            }

            var temporaryRootStagedItems: Int {
                interactiveTemporaryRootStagedItems
                    + trailingTemporaryRootStagedItems
            }

            var temporaryRootShare: Double {
                guard totalStagedItems > 0 else { return 0 }
                return Double(temporaryRootStagedItems)
                    / Double(totalStagedItems)
            }

            func isComplete(scanRoot: String) -> Bool {
                reports.allSatisfy {
                    $0.unresolvedPaths.isEmpty
                        && !$0.rescannedRoots.contains(scanRoot)
                        && !$0.wasCancelled
                }
            }
        }

        private struct MonolithicPatchResult {
            let report: SubtreeRescanReport
            let duration: Double
            let finalStats: TreeStats

            var stagedItems: Int {
                report.metrics.rootStaging.reduce(0) {
                    $0 + $1.actualStagedItemCount
                }
            }

            func isComplete(scanRoot: String) -> Bool {
                report.unresolvedPaths.isEmpty
                    && !report.rescannedRoots.contains(scanRoot)
                    && !report.wasCancelled
            }
        }

        private func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }

        private func elapsed(since start: ContinuousClock.Instant) -> Double {
            seconds(ContinuousClock().now - start)
        }

        private func emptyRescanReport() -> SubtreeRescanReport {
            SubtreeRescanReport(
                requestedPaths: [],
                rescannedRoots: [],
                unresolvedPaths: []
            )
        }

        /// Runs the same synchronous publication boundary as `AppState.commitWarmStart`:
        /// splice, canonical invalidation, then full-tree extension statistics. Scanner-only
        /// timing would prove work moved between tiers without proving the usable interactive
        /// result actually landed sooner.
        @MainActor
        private func runTieredPatch(
            targets: [String],
            tree: FileTree
        ) async -> TieredPatchResult {
            let ephemeralPaths = EphemeralPaths.current()
            let tiers = ephemeralPaths.partition(targets)
            let scanner = FileScanner(
                computeBundleSizes: false,
                deferTreeMaterialization: false
            )
            let progress = ScanProgress()
            let suiteName = Self.tieredPublicationDefaultsSuite
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let publicationState = AppState(defaults: defaults)
            publicationState.fileTree = tree
            publicationState.selectedVolume = URL(
                fileURLWithPath: tree.path(at: 0)
            )
            publicationState.scanProgress.isScanning = true
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let interactiveReport: SubtreeRescanReport
            let interactiveDuration: Double
            if tiers.interactive.isEmpty {
                interactiveReport = emptyRescanReport()
                interactiveDuration = 0
            } else {
                let start = ContinuousClock().now
                interactiveReport = await scanner.rescanSubtrees(
                    tiers.interactive,
                    tree: tree,
                    progress: progress,
                    options: .interactive
                )
                publicationState.invalidateAfterTreeMutation(
                    scheduleDerivedAnalyses: false
                )
                publicationState.computeExtensionStats(
                    loadTemporalSnapshot: false
                )
                interactiveDuration = elapsed(since: start)
            }

            let trailingReport: SubtreeRescanReport
            let trailingDuration: Double
            if tiers.ephemeral.isEmpty {
                trailingReport = emptyRescanReport()
                trailingDuration = 0
            } else {
                let start = ContinuousClock().now
                trailingReport = await scanner.rescanSubtrees(
                    tiers.ephemeral,
                    tree: tree,
                    progress: progress,
                    options: .trailing
                )
                publicationState.invalidateAfterTreeMutation(
                    scheduleDerivedAnalyses: false
                )
                publicationState.computeExtensionStats(
                    loadTemporalSnapshot: false
                )
                trailingDuration = elapsed(since: start)
            }

            return TieredPatchResult(
                interactiveReport: interactiveReport,
                trailingReport: trailingReport,
                interactiveDuration: interactiveDuration,
                trailingDuration: trailingDuration,
                temporaryRoot: ephemeralPaths.darwinUserTemporaryRoot,
                finalStats: treeStats(tree)
            )
        }

        /// Matched pre-change control: the exact same planner target list is rescanned in
        /// one ordinary interactive batch from an independent decode of the same cached
        /// tree. This is the baseline task 4.4 requires; comparing the two new tiers only
        /// would merely measure how much work was deferred, not whether first publication
        /// became faster than the old schedule.
        @MainActor
        private func runMonolithicPatch(
            targets: [String],
            tree: FileTree
        ) async -> MonolithicPatchResult {
            let suiteName = Self.controlPublicationDefaultsSuite
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let publicationState = AppState(defaults: defaults)
            publicationState.fileTree = tree
            publicationState.selectedVolume = URL(
                fileURLWithPath: tree.path(at: 0)
            )
            publicationState.scanProgress.isScanning = true
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }

            let start = ContinuousClock().now
            let report = await FileScanner(
                computeBundleSizes: false,
                deferTreeMaterialization: false
            ).rescanSubtrees(
                targets,
                tree: tree,
                progress: ScanProgress(),
                options: .interactive
            )
            publicationState.invalidateAfterTreeMutation(
                scheduleDerivedAnalyses: false
            )
            publicationState.computeExtensionStats(
                loadTemporalSnapshot: false
            )
            return MonolithicPatchResult(
                report: report,
                duration: elapsed(since: start),
                finalStats: treeStats(tree)
            )
        }

        private func canonicalDirectoryPath(_ requestedPath: String) throws -> String {
            let requested = requestedPath.isEmpty ? "/" : requestedPath
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(requested, &buffer) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            let canonical = buffer.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileReadNoSuchFile.rawValue,
                    userInfo: [NSFilePathErrorKey: canonical]
                )
            }
            return canonical
        }

        private func treeStats(_ tree: FileTree) -> TreeStats {
            let nodes = tree.nodesSnapshot()
            let directories = nodes.reduce(into: 0) { count, node in
                if node.isDirectory { count += 1 }
            }
            let allocatedBytes = nodes.first?.allocatedSize ?? 0
            return TreeStats(
                items: nodes.count,
                directories: directories,
                files: nodes.count - directories,
                allocatedBytes: allocatedBytes
            )
        }

        private func sameTreeStats(_ lhs: TreeStats, _ rhs: TreeStats) -> Bool {
            lhs == rhs
        }

        private func comparableTreeStats(
            _ lhs: TreeStats,
            _ rhs: TreeStats,
            tolerance: Double = 0.005
        ) -> Bool {
            func delta(_ lhs: UInt64, _ rhs: UInt64) -> Double {
                let denominator = max(lhs, rhs, 1)
                return Double(lhs > rhs ? lhs - rhs : rhs - lhs)
                    / Double(denominator)
            }

            return delta(UInt64(lhs.items), UInt64(rhs.items)) <= tolerance
                && delta(
                    UInt64(lhs.directories),
                    UInt64(rhs.directories)
                ) <= tolerance
                && delta(UInt64(lhs.files), UInt64(rhs.files)) <= tolerance
                && delta(lhs.allocatedBytes, rhs.allocatedBytes) <= tolerance
        }

        /// `TASK_VM_INFO` is a read-only query against this benchmark process. It avoids
        /// invoking `ps` or a privileged profiler, and gives both current physical
        /// footprint and the process-wide resident high-water mark.
        private func memorySample() -> MemorySample? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(
                        mach_task_self_,
                        task_flavor_t(TASK_VM_INFO),
                        $0,
                        &count
                    )
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return MemorySample(
                residentBytes: UInt64(info.resident_size),
                physicalFootprintBytes: UInt64(info.phys_footprint),
                peakResidentBytes: UInt64(info.resident_size_peak)
            )
        }

        /// Read-only process accounting from Darwin's `proc_pid_rusage`. Unlike sampling
        /// a child `ps` process, this captures CPU and disk-I/O counters around precisely
        /// the awaited patch call. The counters are process-wide, so the diagnostic is
        /// intentionally serialized and labels them as deltas rather than attributing
        /// them to individual scanner threads.
        private func processResourceSample() -> ProcessResourceSample? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { typedPointer in
                // The imported C API exposes its last argument as `rusage_info_t *`
                // (an optional raw-pointer pointer), while the kernel writes the chosen
                // rusage struct directly into this storage.
                typedPointer.withMemoryRebound(
                    to: rusage_info_t?.self,
                    capacity: 1
                ) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { return nil }
            return ProcessResourceSample(
                userCPUTime: info.ri_user_time,
                systemCPUTime: info.ri_system_time,
                diskBytesRead: info.ri_diskio_bytesread,
                diskBytesWritten: info.ri_diskio_byteswritten,
                instructions: info.ri_instructions,
                cycles: info.ri_cycles,
                residentBytes: info.ri_resident_size,
                physicalFootprintBytes: info.ri_phys_footprint
            )
        }

        private func gibibytes(_ bytes: UInt64) -> String {
            String(format: "%.3f GiB", Double(bytes) / 1_073_741_824)
        }

        private func mebibytes(_ bytes: UInt64) -> String {
            String(format: "%.3f MiB", Double(bytes) / 1_048_576)
        }

        private func cpuSeconds(_ absoluteTimeTicks: UInt64) -> String {
            let nanoseconds = Double(absoluteTimeTicks)
                * Double(Self.machTimebase.numerator)
                / Double(Self.machTimebase.denominator)
            return String(format: "%.6f s", nanoseconds / 1_000_000_000)
        }

        private func counterDelta(_ before: UInt64, _ after: UInt64) -> UInt64 {
            after >= before ? after - before : 0
        }

        private func resourceDeltaDescription(
            before: ProcessResourceSample?,
            after: ProcessResourceSample?
        ) -> String {
            guard let before, let after else {
                return "process_resources=unavailable"
            }
            let instructionDelta = counterDelta(before.instructions, after.instructions)
            let cycleDelta = counterDelta(before.cycles, after.cycles)
            let instructionsPerCycle = cycleDelta > 0
                ? String(format: "%.3f", Double(instructionDelta) / Double(cycleDelta))
                : "unavailable"
            return "user_cpu_delta=\(cpuSeconds(counterDelta(before.userCPUTime, after.userCPUTime))), "
                + "system_cpu_delta=\(cpuSeconds(counterDelta(before.systemCPUTime, after.systemCPUTime))), "
                + "disk_read_delta=\(mebibytes(counterDelta(before.diskBytesRead, after.diskBytesRead))), "
                + "disk_write_delta=\(mebibytes(counterDelta(before.diskBytesWritten, after.diskBytesWritten))), "
                + "instructions_delta=\(instructionDelta), "
                + "cycles_delta=\(cycleDelta), "
                + "instructions_per_cycle=\(instructionsPerCycle), "
                + "resident_before=\(gibibytes(before.residentBytes)), "
                + "resident_after=\(gibibytes(after.residentBytes)), "
                + "footprint_before=\(gibibytes(before.physicalFootprintBytes)), "
                + "footprint_after=\(gibibytes(after.physicalFootprintBytes))"
        }

        private func memoryDescription() -> String {
            guard let sample = memorySample() else { return "memory=unavailable" }
            return "resident=\(gibibytes(sample.residentBytes)), "
                + "footprint=\(gibibytes(sample.physicalFootprintBytes)), "
                + "resident_peak=\(gibibytes(sample.peakResidentBytes))"
        }

        private func cacheSize(for root: String) -> UInt64? {
            let path = TreeCache.cacheURL(for: root).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.uint64Value
        }

        private func formatSeconds(_ value: Double) -> String {
            String(format: "%.6f s", value)
        }

        private func vmLoadAverageDescription() -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
            process.arguments = ["-n", "vm.loadavg"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return process.terminationStatus == 0
                    ? text
                    : "unavailable (sysctl exit \(process.terminationStatus): \(text))"
            } catch {
                return "unavailable (\(error.localizedDescription))"
            }
        }

        private func perRootCachedEstimates(
            for targets: [String],
            cachedTree: FileTree
        ) -> [String: Int] {
            var estimates: [String: Int] = [:]
            estimates.reserveCapacity(targets.count)
            for target in targets {
                estimates[target] = WarmStartPlanner.estimatedPatchItemCount(
                    forChangedPaths: [target],
                    cachedTree: cachedTree
                )
            }
            return estimates
        }

        private func signedInteger(_ value: Int?) -> String {
            guard let value else { return "unavailable" }
            return value >= 0 ? "+\(value)" : "\(value)"
        }

        private func signedPercent(_ value: Double?) -> String {
            guard let value else { return "unavailable" }
            return String(format: "%+.2f%%", value)
        }

        private func printRootStagingDistribution(
            _ rootStaging: [SubtreeRescanMetrics.RootStaging],
            estimatedItemsByPath: [String: Int],
            prefix: String
        ) -> RootStagingDistribution {
            let comparisons: [RootStagingEstimateComparison] =
                rootStaging.map { actual in
                    RootStagingEstimateComparison(
                        path: actual.path,
                        estimatedItemCount: attributedCachedEstimate(
                            contributingRequestedPaths:
                                actual.contributingRequestedPaths,
                            estimatedItemsByRequestedPath:
                                estimatedItemsByPath
                        ),
                        actualStagedItemCount: actual.actualStagedItemCount
                    )
                }
            let distribution = rootStagingDistribution(comparisons)
            for (offset, root) in distribution.rootsByActualItemCount.enumerated() {
                let actualShare = distribution.totalActualStagedItemCount > 0
                    ? Double(root.actualStagedItemCount)
                        / Double(distribution.totalActualStagedItemCount)
                    : 0
                let fields = [
                    "[real-volume warm bench] \(prefix) root staging rank \(offset + 1)",
                    "path=\(root.path)",
                    "estimated_items="
                        + (root.estimatedItemCount.map(String.init) ?? "unavailable"),
                    "actual_staged_items=\(root.actualStagedItemCount)",
                    "estimated_minus_actual="
                        + signedInteger(root.estimateMinusActualItemCount),
                    "estimate_error_percent_of_actual="
                        + signedPercent(root.estimateErrorPercentOfActual),
                    "share_of_actual="
                        + String(format: "%.2f%%", actualShare * 100),
                ]
                print(fields.joined(separator: ", "))
            }
            let summaryFields = [
                "[real-volume warm bench] \(prefix) root staging distribution",
                "roots_reported=\(rootStaging.count)",
                "roots_with_cached_estimate="
                    + String(comparisons.reduce(0) {
                        $0 + ($1.estimatedItemCount == nil ? 0 : 1)
                    }),
                "total_actual_staged_items="
                    + String(distribution.totalActualStagedItemCount),
                "total_estimated_items="
                    + (distribution.totalEstimatedItemCount.map(String.init)
                        ?? "unavailable"),
                "top_root_share="
                    + String(format: "%.2f%%", distribution.topRootShare * 100),
                "single_root_over_half=\(distribution.singleRootOverHalf)",
                "error_sign=estimated_minus_actual "
                    + "(negative means cached estimate undershot live work)",
            ]
            print(summaryFields.joined(separator: ", "))
            return distribution
        }

        private func validateRootStagingEstimates(
            _ distribution: RootStagingDistribution,
            expectedPatchItems: Int?,
            prefix: String
        ) {
            guard let expectedPatchItems else {
                Issue.record(
                    "\(prefix): planner total estimate unavailable for a warm decision"
                )
                return
            }
            guard let attributedTotal = distribution.totalEstimatedItemCount else {
                Issue.record(
                    "\(prefix): at least one staged root lacks its planner-time estimate"
                )
                return
            }
            guard attributedTotal == expectedPatchItems else {
                Issue.record(
                    "\(prefix): per-root estimates total \(attributedTotal), but the planner used \(expectedPatchItems)"
                )
                return
            }
        }

        private func printTreePhase(
            _ name: String,
            duration: Double,
            stats: TreeStats
        ) {
            print(
                "[real-volume warm bench] \(name): \(formatSeconds(duration)); "
                    + "items=\(stats.items), dirs=\(stats.directories), files=\(stats.files), "
                    + "allocated=\(gibibytes(stats.allocatedBytes)); \(memoryDescription())"
            )
        }

        private func printRescanMetrics(
            _ metrics: SubtreeRescanMetrics,
            prefix: String
        ) {
            let attributedSeconds =
                metrics.preflightAndPlanningSeconds
                + metrics.phaseAStagingSeconds
                + metrics.phaseBTargetResolutionSeconds
                + metrics.phaseBStructuralCompactionSeconds
                + metrics.postCommitMetadataSeconds
                + metrics.aggregateRecomputeSeconds
            let unattributedSeconds = max(0, metrics.totalSeconds - attributedSeconds)
            print(
                "[real-volume warm bench] \(prefix) phase timings: "
                    + "preflight_and_planning="
                    + "\(formatSeconds(metrics.preflightAndPlanningSeconds)), "
                    + "phase_a_staging=\(formatSeconds(metrics.phaseAStagingSeconds)), "
                    + "phase_b_target_resolution="
                    + "\(formatSeconds(metrics.phaseBTargetResolutionSeconds)), "
                    + "phase_b_structural_compaction="
                    + "\(formatSeconds(metrics.phaseBStructuralCompactionSeconds)), "
                    + "post_commit_metadata="
                    + "\(formatSeconds(metrics.postCommitMetadataSeconds)), "
                    + "aggregate_recompute="
                    + "\(formatSeconds(metrics.aggregateRecomputeSeconds)), "
                    + "unattributed=\(formatSeconds(unattributedSeconds)), "
                    + "instrumented_total=\(formatSeconds(metrics.totalSeconds))"
            )
            print(
                "[real-volume warm bench] \(prefix) workload counts: "
                    + "nodes_before=\(metrics.beforeNodeCount), "
                    + "nodes_staged=\(metrics.stagedNodeCount), "
                    + "nodes_removed=\(metrics.removedNodeCount), "
                    + "nodes_appended=\(metrics.appendedNodeCount), "
                    + "requested_paths=\(metrics.requestedPathCount), "
                    + "rescanned_roots=\(metrics.rescannedRootCount), "
                    + "planned_roots=\(metrics.plannedRootCount), "
                    + "staged_roots=\(metrics.stagedRootCount), "
                    + "resolved_targets=\(metrics.resolvedTargetCount), "
                    + "structural_replacements="
                    + "\(metrics.structurallyReplacedRootCount), "
                    + "applied_roots=\(metrics.appliedRootCount)"
            )
        }

        private func printTieredPatchSummary(
            _ result: TieredPatchResult,
            prefix: String
        ) {
            print(
                "[real-volume warm bench] \(prefix) tier summary: "
                    + "interactive_time_to_publication="
                    + "\(formatSeconds(result.interactiveDuration)), "
                    + "trailing_time_to_final_publication="
                    + "\(formatSeconds(result.trailingDuration)), "
                    + "total_time_to_final_publication="
                    + "\(formatSeconds(result.totalDuration)), "
                    + "interactive_staged_items=\(result.interactiveStagedItems), "
                    + "trailing_staged_items=\(result.trailingStagedItems), "
                    + "interactive_temporary_root_staged_items="
                    + "\(result.interactiveTemporaryRootStagedItems), "
                    + "trailing_temporary_root_staged_items="
                    + "\(result.trailingTemporaryRootStagedItems), "
                    + "temporary_root_staged_items="
                    + "\(result.temporaryRootStagedItems), "
                    + "temporary_root_share="
                    + String(format: "%.2f%%", result.temporaryRootShare * 100)
            )
            printRescanMetrics(
                result.interactiveReport.metrics,
                prefix: "\(prefix) interactive tier"
            )
            printRescanMetrics(
                result.trailingReport.metrics,
                prefix: "\(prefix) trailing tier"
            )
        }

        /// Compare first-tier time-to-publication with the old one-batch schedule on the
        /// same planner target list and cached baseline. Both durations include production's
        /// synchronous invalidation and full-tree extension-stat pass. The diagnostic
        /// predicted a 42-52% staged-work reduction; 15% is the deliberately conservative
        /// floor for "material". No absolute target is involved.
        private func validateMaterialInteractiveTier(
            _ result: TieredPatchResult,
            control: MonolithicPatchResult,
            prefix: String,
            requiresTemporaryWork: Bool,
            controlRanFirst: Bool = true,
            enforceTiming: Bool = true
        ) -> RealVolumeDiagnosticTimingPair? {
            if requiresTemporaryWork {
                #expect(
                    result.interactiveTemporaryRootStagedItems == 0,
                    "\(prefix): Darwin temp work leaked into the interactive tier"
                )
                #expect(
                    result.trailingTemporaryRootStagedItems > 0,
                    "\(prefix): diagnostic workload did not move Darwin temp work into the trailing tier"
                )
                guard result.interactiveTemporaryRootStagedItems == 0,
                      result.trailingTemporaryRootStagedItems > 0 else {
                    return nil
                }
            } else if result.trailingStagedItems == 0 {
                print(
                    "[real-volume warm bench] \(prefix) interactive improvement gate: "
                        + "not exercised (this ordinary refresh had no ephemeral targets)"
                )
                return nil
            }

            #expect(
                result.trailingStagedItems > 0,
                "\(prefix): no trailing work was staged; the two-tier gate was not exercised"
            )
            guard result.trailingStagedItems > 0,
                  control.duration > 0 else {
                return nil
            }
            guard result.interactiveStagedItems > 0,
                  result.interactiveDuration > 0 else {
                print(
                    "[real-volume warm bench] \(prefix) interactive improvement gate: "
                        + "not exercised (all staged work was ephemeral)"
                )
                return nil
            }

            let comparableFinalTrees = comparableTreeStats(
                control.finalStats,
                result.finalStats
            )
            #expect(
                comparableFinalTrees,
                "\(prefix): matched control and tiered run did not produce comparable final tree stats"
            )
            guard comparableFinalTrees else { return nil }

            // The live filesystem can drift between the independently decoded control
            // and tiered runs. Refuse a timing comparison if their actual Phase A work is
            // not within 5%; a fast result from materially less work is not evidence.
            let stagedDenominator = max(control.stagedItems, result.totalStagedItems, 1)
            let stagedDelta = abs(control.stagedItems - result.totalStagedItems)
            let stagedDeltaFraction =
                Double(stagedDelta) / Double(stagedDenominator)
            #expect(
                stagedDeltaFraction <= 0.05,
                "\(prefix): matched control and tiered run staged materially different work (\(control.stagedItems) vs \(result.totalStagedItems))"
            )
            guard stagedDeltaFraction
                    <= RealVolumeDiagnosticTimingPolicy.stagedWorkTolerance else {
                return nil
            }

            let pair = RealVolumeDiagnosticTimingPair(
                controlDuration: control.duration,
                interactiveDuration: result.interactiveDuration,
                controlStagedItems: control.stagedItems,
                tieredStagedItems: result.totalStagedItems,
                interactiveStagedItems: result.interactiveStagedItems,
                controlRanFirst: controlRanFirst
            )
            guard enforceTiming else { return pair }

            let improvement =
                pair.relativeImprovement
            let stagedReduction =
                Double(max(0, control.stagedItems - result.interactiveStagedItems))
                / Double(max(control.stagedItems, 1))
            print(
                "[real-volume warm bench] \(prefix) interactive improvement gate: "
                    + "monolithic_control_time_to_publication="
                    + formatSeconds(pair.controlDuration)
                    + ", interactive_time_to_publication="
                    + formatSeconds(pair.interactiveDuration)
                    + ", relative_time_to_publication_saved="
                    + String(format: "%.2f%%", improvement * 100)
                    + ", interactive_staged_item_reduction="
                    + String(format: "%.2f%%", stagedReduction * 100)
                    + ", matched_staged_item_delta="
                    + String(format: "%.2f%%", stagedDeltaFraction * 100)
                    + ", required="
                    + String(
                        format: "%.2f%%",
                        RealVolumeDiagnosticTimingPolicy.materialImprovementFloor
                            * 100
                    )
                    + ", absolute_target=none"
            )
            #expect(
                improvement
                    >= RealVolumeDiagnosticTimingPolicy.materialImprovementFloor,
                "\(prefix): interactive publication improved only \(String(format: "%.2f%%", improvement * 100)) against the matched monolithic control"
            )
            return pair
        }

        private func validateControlBaseline(
            _ control: MonolithicPatchResult,
            root: String,
            prefix: String
        ) -> Bool {
            guard control.isComplete(scanRoot: root) else {
                Issue.record(
                    "\(prefix): matched monolithic control was incomplete"
                )
                return false
            }
            print(
                "[real-volume warm bench] \(prefix) matched monolithic control: "
                    + "time_to_publication=\(formatSeconds(control.duration)), "
                    + "staged_items=\(control.stagedItems)"
            )
            return true
        }

        private struct DiagnosticTieredSample {
            let payload: TreeCache.Payload?
            let result: TieredPatchResult
            let patchedStats: TreeStats
        }

        private func runDiagnosticControlSample(
            root: String,
            targets: [String],
            prePatchEventId: UInt64,
            prePatchStats: TreeStats,
            prefix: String
        ) async -> MonolithicPatchResult? {
            var payload = TreeCache.load(for: root)
            guard payload != nil else {
                Issue.record("\(prefix): matched control cache failed to reload")
                return nil
            }
            guard payload!.lastEventId == prePatchEventId,
                  sameTreeStats(treeStats(payload!.tree), prePatchStats) else {
                Issue.record(
                    "\(prefix): matched control did not reload the same pre-patch baseline"
                )
                return nil
            }
            let result = await runMonolithicPatch(
                targets: targets,
                tree: payload!.tree
            )
            guard validateControlBaseline(
                result,
                root: root,
                prefix: prefix
            ) else {
                return nil
            }
            payload = nil
            return result
        }

        private func runDiagnosticTieredSample(
            root: String,
            targets: [String],
            prePatchEventId: UInt64,
            prePatchStats: TreeStats,
            expectedPatchItems: Int?,
            prefix: String,
            retainPayload: Bool
        ) async -> DiagnosticTieredSample? {
            let clock = ContinuousClock()
            let loadStart = clock.now
            guard let payload = TreeCache.load(for: root) else {
                Issue.record("\(prefix): pre-patch scratch cache failed to reload")
                return nil
            }
            let loadDuration = elapsed(since: loadStart)
            let baselineStats = treeStats(payload.tree)
            guard payload.lastEventId == prePatchEventId,
                  sameTreeStats(baselineStats, prePatchStats) else {
                Issue.record(
                    "\(prefix): scratch cache did not reload the same pre-patch baseline"
                )
                return nil
            }
            print(
                "[real-volume warm bench] \(prefix) cache reload: "
                    + "\(formatSeconds(loadDuration)); "
                    + "event_id=\(payload.lastEventId), "
                    + "items=\(baselineStats.items), "
                    + "dirs=\(baselineStats.directories)"
            )

            // Estimate lookup is diagnostic overhead, not publication time.
            let rootEstimates = perRootCachedEstimates(
                for: targets,
                cachedTree: payload.tree
            )
            let resourcesBefore = processResourceSample()
            let result = await runTieredPatch(
                targets: targets,
                tree: payload.tree
            )
            let resourcesAfter = processResourceSample()
            let patchedStats = treeStats(payload.tree)
            printTreePhase(
                "\(prefix) warm patch "
                    + "(requested="
                    + "\(result.reports.reduce(0) { $0 + $1.requestedPaths.count }), "
                    + "rescanned="
                    + "\(result.reports.reduce(0) { $0 + $1.rescannedRoots.count }), "
                    + "unresolved="
                    + "\(result.reports.reduce(0) { $0 + $1.unresolvedPaths.count }), "
                    + "cancelled="
                    + "\(result.reports.contains { $0.wasCancelled }))",
                duration: result.totalDuration,
                stats: patchedStats
            )
            printTieredPatchSummary(result, prefix: prefix)
            let distribution = printRootStagingDistribution(
                result.combinedRootStaging,
                estimatedItemsByPath: rootEstimates,
                prefix: prefix
            )
            validateRootStagingEstimates(
                distribution,
                expectedPatchItems: expectedPatchItems,
                prefix: prefix
            )
            print(
                "[real-volume warm bench] \(prefix) resources: "
                    + resourceDeltaDescription(
                        before: resourcesBefore,
                        after: resourcesAfter
                    )
            )
            guard result.isComplete(scanRoot: root) else {
                Issue.record("\(prefix): warm patch was incomplete")
                return nil
            }
            return DiagnosticTieredSample(
                payload: retainPayload ? payload : nil,
                result: result,
                patchedStats: patchedStats
            )
        }

        /// Read-only with respect to pre-existing content in the selected scan root. The
        /// only writes made by this benchmark are self-owned TreeCache files beneath the
        /// unique temporary App Support directory installed by
        /// `withTemporaryAppSupportDir`; that exact scratch directory is removed by the
        /// helper afterward. The benchmark never edits, renames, trashes, or deletes
        /// pre-existing content in the selected volume.
        @Test(
            "Cold scan followed by bounded real FSEvents warm-refresh attempts",
            .timeLimit(.minutes(30))
        )
        func coldThenRepeatedWarmRefreshes() async throws {
#if DEBUG
            Issue.record(
                "Real-volume timing must use an optimized build: swift test -c release --filter RealVolumeWarmStartBenchmarkTests"
            )
            return
#else
            let requestedRoot =
                ProcessInfo.processInfo.environment["DIRWIZ_REAL_VOLUME_BENCH_ROOT"] ?? "/"
            let root = try canonicalDirectoryPath(requestedRoot)
            let clock = ContinuousClock()
            let refreshAttemptLimit =
                RealVolumeDiagnosticPolicy.refreshAttemptLimit(
                    diagnosticEnabled: runRealVolumeWarmStartDiagnostics
                )

            try await withTemporaryAppSupportDir {
                var completedComparableDiagnosticWorkloads = 0
                var diagnosticWorkloadOrdinal = 0
                var balancedWorkloadImprovements: [Double] = []
                let scratchRoot = try #require(
                    ProcessInfo.processInfo.environment["DIRWIZ_APP_SUPPORT_DIR"],
                    "temporary App Support override was not installed"
                )
                let scratchURL = URL(fileURLWithPath: scratchRoot, isDirectory: true)
                    .standardizedFileURL
                let systemTemporaryURL = FileManager.default.temporaryDirectory
                    .standardizedFileURL
                #expect(
                    scratchURL.path.hasPrefix(systemTemporaryURL.path + "/"),
                    "refusing to benchmark unless TreeCache is redirected beneath the system temporary directory"
                )
                guard scratchURL.path.hasPrefix(systemTemporaryURL.path + "/") else {
                    return
                }

                print(
                    "[real-volume warm bench] BEGIN root=\(root), "
                        + "refresh_attempt_limit=\(refreshAttemptLimit), "
                        + "scratch_app_support=\(scratchRoot), "
                        + "diagnostic_replay=\(runRealVolumeWarmStartDiagnostics), "
                        + "diagnostic_workloads_required="
                        + "\(RealVolumeDiagnosticPolicy.requiredWarmWorkloadCount), "
                        + "diagnostic_samples_per_workload="
                        + "\(Self.diagnosticPatchSampleCount)"
                )
                print(
                    "[real-volume warm bench] pre-timing vm.loadavg="
                        + vmLoadAverageDescription()
                )
                print(
                    "[real-volume warm bench] safety: no mutation of pre-existing root content; "
                        + "scratch cache only; bundle sizing disabled; immediate headless materialisation"
                )
                if runRealVolumeWarmStartDiagnostics {
                    print(
                        "[real-volume warm bench] diagnostic mode: three distinct non-empty "
                            + "production-planner warm decisions are required; each decision's "
                            + "target list is replayed from a fresh decode of the same pre-patch "
                            + "scratch cache for one excluded control/tiered warm-up and four "
                            + "timed crossover pairs with balanced run order; "
                            + "enable only with DIRWIZ_REAL_VOLUME_BENCH=1 "
                            + "DIRWIZ_REAL_VOLUME_DIAGNOSTIC=1 in a Release build"
                    )
                }

                // Capture before enumeration, exactly like AppState's cold path. Events
                // that happen while a long scan is in flight must be replayed afterward.
                let initialEventId = FSEventsJournal.currentEventId()
                var bootstrapTree: FileTree? = FileTree()
                let coldStart = clock.now
                await FileScanner(
                    computeBundleSizes: false,
                    deferTreeMaterialization: false
                ).scan(
                    path: root,
                    progress: ScanProgress(),
                    tree: bootstrapTree!
                )
                let coldDuration = elapsed(since: coldStart)
                let initialStats = treeStats(bootstrapTree!)
                printTreePhase("initial cold scan", duration: coldDuration, stats: initialStats)

                let initialSaveStart = clock.now
                try TreeCache.save(tree: bootstrapTree!, lastEventId: initialEventId)
                let initialSaveDuration = elapsed(since: initialSaveStart)
                let initialCacheBytes = cacheSize(for: root)
                print(
                    "[real-volume warm bench] initial cache save: "
                        + "\(formatSeconds(initialSaveDuration)); "
                        + "cache=\(initialCacheBytes.map(gibibytes) ?? "unavailable"); "
                        + "\(memoryDescription())"
                )

                // Do not retain the original in-memory tree while loading the persisted
                // copy. This keeps peak memory representative of launch behavior rather
                // than measuring two complete trees held by the test itself.
                bootstrapTree = nil

                refreshAttempts: for refresh in 1...refreshAttemptLimit {
                    var payload: TreeCache.Payload?
                    let loadStart = clock.now
                    payload = TreeCache.load(for: root)
                    let loadDuration = elapsed(since: loadStart)
                    guard payload != nil else {
                        Issue.record("refresh \(refresh): scratch TreeCache failed to load")
                        return
                    }
                    let cachedStats = treeStats(payload!.tree)
                    print(
                        "[real-volume warm bench] refresh \(refresh) cache load: "
                            + "\(formatSeconds(loadDuration)); items=\(cachedStats.items), "
                            + "dirs=\(cachedStats.directories); \(memoryDescription())"
                    )

                    let replayStart = clock.now
                    let replay = await FSEventsJournal.replay(
                        root: root,
                        since: payload!.lastEventId,
                        timeout: 30
                    )
                    let replayDuration = elapsed(since: replayStart)

                    let rawChangedCount: Int
                    let collapsedChangedCount: Int
                    let estimatedPatchItems: Int?
                    switch replay.outcome {
                    case .changes(let changedPaths):
                        rawChangedCount = changedPaths.count
                        collapsedChangedCount = PathCollapse.outermostRoots(changedPaths).count
                        estimatedPatchItems = WarmStartPlanner.estimatedPatchItemCount(
                            forChangedPaths: changedPaths,
                            cachedTree: payload!.tree
                        )
                    case .poisoned:
                        rawChangedCount = 0
                        collapsedChangedCount = 0
                        estimatedPatchItems = nil
                    }
                    print(
                        "[real-volume warm bench] refresh \(refresh) journal replay: "
                            + "\(formatSeconds(replayDuration)); raw_paths=\(rawChangedCount), "
                            + "collapsed_roots=\(collapsedChangedCount), "
                            + "estimated_patch_items=\(estimatedPatchItems.map(String.init) ?? "unavailable")"
                    )

                    let plannerStart = clock.now
                    let decision = WarmStartPlanner.decide(
                        cacheAvailable: true,
                        replay: replay.outcome,
                        cachedDirectoryCount: cachedStats.directories,
                        cachedTotalItemCount: cachedStats.items,
                        estimatedPatchItems: estimatedPatchItems
                    )
                    let plannerDuration = elapsed(since: plannerStart)

                    switch decision {
                    case .warm(let targets):
                        print(
                            "[real-volume warm bench] refresh \(refresh) planner: "
                                + "\(formatSeconds(plannerDuration)); decision=warm, "
                                + "targets=\(targets.count)"
                        )

                        let patchResult: TieredPatchResult
                        let controlResult: MonolithicPatchResult
                        let diagnosticEphemeralPaths = EphemeralPaths.current()
                        let diagnosticTargetTiers =
                            diagnosticEphemeralPaths.partition(targets)
                        let diagnosticTemporaryTargetCount =
                            diagnosticTargetTiers.ephemeral.filter { target in
                                guard let temporaryRoot =
                                        diagnosticEphemeralPaths
                                            .darwinUserTemporaryRoot else {
                                    return false
                                }
                                return target == temporaryRoot
                                    || target.hasPrefix(temporaryRoot + "/")
                            }.count
                        if RealVolumeDiagnosticPolicy.shouldCollect(
                            diagnosticEnabled: runRealVolumeWarmStartDiagnostics,
                            interactiveTargetCount:
                                diagnosticTargetTiers.interactive.count,
                            temporaryTargetCount:
                                diagnosticTemporaryTargetCount
                        ) {
                            // Preserve the exact output of this one planner decision.
                            // There is no second journal replay or collapse between
                            // samples: every direct rescan receives this same value.
                            let diagnosticTargets = Array(targets)
                            let prePatchEventId = payload!.lastEventId
                            let prePatchStats = cachedStats
                            print(
                                "[real-volume warm bench] refresh \(refresh) diagnostic workload: "
                                    + "targets=\(diagnosticTargets.count), "
                                    + "estimated_cached_items="
                                    + "\(estimatedPatchItems.map(String.init) ?? "unavailable"), "
                                    + "baseline_items=\(prePatchStats.items), "
                                    + "baseline_dirs=\(prePatchStats.directories), "
                                    + "baseline_files=\(prePatchStats.files)"
                            )

                            // Release this initial decode. Each sample below reloads the
                            // still-unmodified cache file, and no sample writes it back.
                            payload = nil
                            diagnosticWorkloadOrdinal += 1
                            var durations: [Double] = []
                            durations.reserveCapacity(Self.diagnosticPatchSampleCount)
                            var timingPairs: [RealVolumeDiagnosticTimingPair] = []
                            timingPairs.reserveCapacity(
                                Self.diagnosticPatchSampleCount
                            )
                            var firstPatchedStats: TreeStats?
                            var patchedStatsComparable = true
                            var lastControlResult: MonolithicPatchResult?

                            // Odd workloads use ABBA and even workloads use BAAB. Each
                            // workload therefore has two samples in each reciprocal order,
                            // while alternating the pattern avoids a systematic workload-
                            // position preference in the aggregate.
                            let controlFirstBySample =
                                diagnosticWorkloadOrdinal.isMultiple(of: 2)
                                    ? [false, true, true, false]
                                    : [true, false, false, true]

                            // Prime both schedules in the same order as sample one. The
                            // warm-up therefore ends with the opposite schedule from the
                            // first timed run in both ABBA and BAAB, avoiding a hidden
                            // immediate self-carryover advantage. Validate the pair, then
                            // exclude it from all timing arrays.
                            let warmUpPrefix =
                                "refresh \(refresh) diagnostic warm-up (excluded)"
                            let warmUpControl: MonolithicPatchResult
                            let warmUpTiered: DiagnosticTieredSample
                            let warmUpControlFirst = controlFirstBySample[0]
                            if warmUpControlFirst {
                                guard let control =
                                        await runDiagnosticControlSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            prefix: warmUpPrefix
                                        ),
                                      let tiered =
                                        await runDiagnosticTieredSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            expectedPatchItems:
                                                estimatedPatchItems,
                                            prefix: warmUpPrefix,
                                            retainPayload: false
                                        ) else {
                                    return
                                }
                                warmUpControl = control
                                warmUpTiered = tiered
                            } else {
                                guard let tiered =
                                        await runDiagnosticTieredSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            expectedPatchItems:
                                                estimatedPatchItems,
                                            prefix: warmUpPrefix,
                                            retainPayload: false
                                        ),
                                      let control =
                                        await runDiagnosticControlSample(
                                        root: root,
                                        targets: diagnosticTargets,
                                        prePatchEventId: prePatchEventId,
                                        prePatchStats: prePatchStats,
                                        prefix: warmUpPrefix
                                    ) else {
                                    return
                                }
                                warmUpTiered = tiered
                                warmUpControl = control
                            }
                            guard validateMaterialInteractiveTier(
                                    warmUpTiered.result,
                                    control: warmUpControl,
                                    prefix: warmUpPrefix,
                                    requiresTemporaryWork: true,
                                    controlRanFirst: warmUpControlFirst,
                                    enforceTiming: false
                                  ) != nil else {
                                Issue.record(
                                    "refresh \(refresh): excluded diagnostic warm-up was not comparable"
                                )
                                return
                            }
                            print(
                                "[real-volume warm bench] \(warmUpPrefix): "
                                    + "order="
                                    + (warmUpControlFirst
                                        ? "monolithic-then-tiered"
                                        : "tiered-then-monolithic")
                                    + ", validated and excluded from timing gate"
                            )

                            for sample in 1...Self.diagnosticPatchSampleCount {
                                let prefix =
                                    "refresh \(refresh) diagnostic sample \(sample)"
                                let controlFirst =
                                    controlFirstBySample[sample - 1]
                                print(
                                    "[real-volume warm bench] \(prefix) order: "
                                        + (controlFirst
                                            ? "monolithic-then-tiered"
                                            : "tiered-then-monolithic")
                                )

                                let sampleControlResult: MonolithicPatchResult
                                let sampleTiered: DiagnosticTieredSample
                                if controlFirst {
                                    guard let control =
                                        await runDiagnosticControlSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            prefix: prefix
                                        ) else {
                                        return
                                    }
                                    sampleControlResult = control
                                    guard let tiered =
                                        await runDiagnosticTieredSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            expectedPatchItems: estimatedPatchItems,
                                            prefix: prefix,
                                            retainPayload: false
                                        ) else {
                                        return
                                    }
                                    sampleTiered = tiered
                                } else {
                                    guard let tiered =
                                        await runDiagnosticTieredSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            expectedPatchItems: estimatedPatchItems,
                                            prefix: prefix,
                                            retainPayload: false
                                        ) else {
                                        return
                                    }
                                    sampleTiered = tiered
                                    guard let control =
                                        await runDiagnosticControlSample(
                                            root: root,
                                            targets: diagnosticTargets,
                                            prePatchEventId: prePatchEventId,
                                            prePatchStats: prePatchStats,
                                            prefix: prefix
                                        ) else {
                                        return
                                    }
                                    sampleControlResult = control
                                }

                                let samplePatchResult = sampleTiered.result
                                durations.append(samplePatchResult.totalDuration)
                                lastControlResult = sampleControlResult
                                if let firstPatchedStats {
                                    if !comparableTreeStats(
                                        sampleTiered.patchedStats,
                                        firstPatchedStats
                                    ) {
                                        patchedStatsComparable = false
                                    }
                                } else {
                                    firstPatchedStats =
                                        sampleTiered.patchedStats
                                }
                                if let pair = validateMaterialInteractiveTier(
                                    samplePatchResult,
                                    control: sampleControlResult,
                                    prefix: prefix,
                                    requiresTemporaryWork: true,
                                    controlRanFirst: controlFirst,
                                    enforceTiming: false
                                ) {
                                    timingPairs.append(pair)
                                }
                            }

                            // Timed tiered samples deliberately return no payload. In a
                            // tiered-first pair this ensures its multi-million-node tree
                            // is released BEFORE the control starts, matching the
                            // control-first order where the control tree is released
                            // before tiered. Run one additional, explicitly non-timing
                            // tiered publication to obtain the production-equivalent
                            // payload that advances the refresh loop.
                            guard let finalTiered =
                                    await runDiagnosticTieredSample(
                                        root: root,
                                        targets: diagnosticTargets,
                                        prePatchEventId: prePatchEventId,
                                        prePatchStats: prePatchStats,
                                        expectedPatchItems: estimatedPatchItems,
                                        prefix:
                                            "refresh \(refresh) diagnostic final publication (not a timing sample)",
                                        retainPayload: true
                                    ),
                                  let selectedPayload = finalTiered.payload,
                                  let selectedControlResult = lastControlResult else {
                                Issue.record(
                                    "refresh \(refresh): diagnostic samples produced no final tree"
                                )
                                return
                            }
                            payload = selectedPayload
                            patchResult = finalTiered.result
                            controlResult = selectedControlResult
                            let orderedDurations = durations.sorted()
                            let orderedControlDurations =
                                timingPairs.map(\.controlDuration).sorted()
                            let orderedInteractiveDurations =
                                timingPairs.map(\.interactiveDuration).sorted()
                            let medianControlDuration =
                                RealVolumeDiagnosticTimingPolicy.median(
                                    orderedControlDurations
                                )
                            let medianInteractiveDuration =
                                RealVolumeDiagnosticTimingPolicy.median(
                                    orderedInteractiveDurations
                                )
                            let medianDuration =
                                RealVolumeDiagnosticTimingPolicy.median(
                                    orderedDurations
                                )
                            let stagedWorkComparable =
                                RealVolumeDiagnosticTimingPolicy.isComparable(
                                    timingPairs,
                                    expectedCount:
                                        Self.diagnosticPatchSampleCount
                                )
                            if patchedStatsComparable,
                               stagedWorkComparable,
                               let balancedEffect =
                                RealVolumeDiagnosticTimingPolicy
                                    .balancedEffect(timingPairs),
                               balancedEffect.orderBlockLogRatioDelta
                                <= RealVolumeDiagnosticTimingPolicy
                                    .maximumOrderBlockLogRatioDelta,
                               let medianDuration,
                               let medianControlDuration,
                               let medianInteractiveDuration {
                                completedComparableDiagnosticWorkloads += 1
                                balancedWorkloadImprovements.append(
                                    balancedEffect.relativeImprovement
                                )
                                print(
                                    "[real-volume warm bench] refresh \(refresh) "
                                        + "diagnostic balanced crossover (report-only): "
                                        + "relative_time_to_publication_saved="
                                        + String(
                                            format: "%.2f%%",
                                            balancedEffect.relativeImprovement
                                                * 100
                                        )
                                        + ", control_first_mean_log_ratio="
                                        + String(
                                            format: "%.6f",
                                            balancedEffect
                                                .controlFirstMeanLogRatio
                                        )
                                        + ", tiered_first_mean_log_ratio="
                                        + String(
                                            format: "%.6f",
                                            balancedEffect
                                                .tieredFirstMeanLogRatio
                                        )
                                        + ", order_block_log_ratio_delta="
                                        + String(
                                            format: "%.6f",
                                            balancedEffect
                                                .orderBlockLogRatioDelta
                                        )
                                        + ", aggregate_gate_pending=true"
                                )
                                // One completed workload means one distinct non-empty,
                                // timing-comparable planner decision/FSEvents replay
                                // window. The crossover pairs characterize that ONE
                                // workload and never count as independent decisions.
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic summary: "
                                        + "samples=\(durations.count), comparable=true, "
                                        + "min=\(formatSeconds(orderedDurations.first!)), "
                                        + "median=\(formatSeconds(medianDuration)), "
                                        + "max=\(formatSeconds(orderedDurations.last!)), "
                                        + "monolithic_control_duration_median_report_only="
                                        + "\(formatSeconds(medianControlDuration)), "
                                        + "interactive_publication_duration_median_report_only="
                                        + "\(formatSeconds(medianInteractiveDuration)), "
                                        + "balanced_relative_improvement="
                                        + String(
                                            format: "%.2f%%",
                                            balancedEffect.relativeImprovement
                                                * 100
                                        )
                                )
                            } else {
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic summary: "
                                        + "samples=\(durations.count), comparable=false, "
                                        + "balanced effect refused because final-tree stats, "
                                        + "paired staged work, cross-sample staged work, "
                                        + "reciprocal run order, order-block consistency, "
                                        + "or non-ephemeral interactive work was not comparable; "
                                        + "min_observed=\(formatSeconds(orderedDurations.first!)), "
                                        + "max_observed=\(formatSeconds(orderedDurations.last!))"
                                )
                            }
                        } else {
                            if runRealVolumeWarmStartDiagnostics {
                                let interactiveCount =
                                    diagnosticTargetTiers.interactive.count
                                let ephemeralCount =
                                    diagnosticTargetTiers.ephemeral.count
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic workload not collected: interactive_targets=\(interactiveCount), ephemeral_targets=\(ephemeralCount), temporary_targets=\(diagnosticTemporaryTargetCount); interactive and Darwin-temp work are required"
                                )
                            }
                            // As above, keep cached-tree estimate lookup out of the warm
                            // patch's measured interval.
                            let rootEstimates = perRootCachedEstimates(
                                for: targets,
                                cachedTree: payload!.tree
                            )
                            let productionBaselineEventId =
                                payload!.lastEventId
                            let productionBaselineStats =
                                treeStats(payload!.tree)
                            var matchedControlPayload =
                                TreeCache.load(for: root)
                            guard matchedControlPayload != nil,
                                  matchedControlPayload!.lastEventId
                                    == productionBaselineEventId,
                                  sameTreeStats(
                                      treeStats(matchedControlPayload!.tree),
                                      productionBaselineStats
                                  ) else {
                                Issue.record(
                                    "refresh \(refresh): matched monolithic control did not reload the production baseline"
                                )
                                return
                            }
                            controlResult = await runMonolithicPatch(
                                targets: targets,
                                tree: matchedControlPayload!.tree
                            )
                            guard validateControlBaseline(
                                controlResult,
                                root: root,
                                prefix: "refresh \(refresh) warm patch"
                            ) else {
                                return
                            }
                            matchedControlPayload = nil
                            patchResult = await runTieredPatch(
                                targets: targets,
                                tree: payload!.tree
                            )
                            let distribution = printRootStagingDistribution(
                                patchResult.combinedRootStaging,
                                estimatedItemsByPath: rootEstimates,
                                prefix: "refresh \(refresh) warm patch"
                            )
                            validateRootStagingEstimates(
                                distribution,
                                expectedPatchItems: estimatedPatchItems,
                                prefix: "refresh \(refresh) warm patch"
                            )
                        }

                        let patchedStats = treeStats(payload!.tree)
                        printTreePhase(
                            "refresh \(refresh) warm patch "
                                + "(requested="
                                + "\(patchResult.reports.reduce(0) { $0 + $1.requestedPaths.count }), "
                                + "rescanned="
                                + "\(patchResult.reports.reduce(0) { $0 + $1.rescannedRoots.count }), "
                                + "unresolved="
                                + "\(patchResult.reports.reduce(0) { $0 + $1.unresolvedPaths.count }), "
                                + "cancelled="
                                + "\(patchResult.reports.contains { $0.wasCancelled }))",
                            duration: patchResult.totalDuration,
                            stats: patchedStats
                        )
                        if !runRealVolumeWarmStartDiagnostics {
                            printTieredPatchSummary(
                                patchResult,
                                prefix: "refresh \(refresh) warm patch"
                            )
                            _ = validateMaterialInteractiveTier(
                                patchResult,
                                control: controlResult,
                                prefix: "refresh \(refresh) warm patch",
                                requiresTemporaryWork: false,
                                enforceTiming: false
                            )
                            print(
                                "[real-volume warm bench] refresh \(refresh) ordinary timing: "
                                    + "report-only; the material-improvement gate uses "
                                    + "the three-workload order-balanced diagnostic median"
                            )
                        }

                        guard patchResult.isComplete(scanRoot: root) else {
                            Issue.record(
                                "refresh \(refresh): warm patch was incomplete; refusing to save that tree"
                            )
                            return
                        }

                        let saveStart = clock.now
                        try TreeCache.save(
                            tree: payload!.tree,
                            lastEventId: replay.newEventId
                        )
                        let saveDuration = elapsed(since: saveStart)
                        print(
                            "[real-volume warm bench] refresh \(refresh) warm cache save: "
                                + "\(formatSeconds(saveDuration)); "
                                + "cache=\(cacheSize(for: root).map(gibibytes) ?? "unavailable"); "
                                + "\(memoryDescription())"
                        )
                        if runRealVolumeWarmStartDiagnostics,
                           RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(
                               completedComparableDiagnosticWorkloads
                           ) {
                            print(
                                "[real-volume warm bench] diagnostic collection complete: "
                                    + "completed_comparable_non_empty_workloads="
                                    + "\(completedComparableDiagnosticWorkloads), "
                                    + "samples_per_workload="
                                    + "\(Self.diagnosticPatchSampleCount), "
                                    + "refresh_attempt=\(refresh)"
                            )
                            break refreshAttempts
                        }

                    case .coldFallback(let reason):
                        print(
                            "[real-volume warm bench] refresh \(refresh) planner: "
                                + "\(formatSeconds(plannerDuration)); decision=cold; "
                                + "reason=\(reason)"
                        )

                        // Drop the decoded cache before allocating another multi-million
                        // node tree. The cold fallback below is the production behavior,
                        // not a synthetic shortcut.
                        payload = nil
                        let fallbackEventId = FSEventsJournal.currentEventId()
                        let fallbackTree = FileTree()
                        let fallbackStart = clock.now
                        await FileScanner(
                            computeBundleSizes: false,
                            deferTreeMaterialization: false
                        ).scan(
                            path: root,
                            progress: ScanProgress(),
                            tree: fallbackTree
                        )
                        let fallbackDuration = elapsed(since: fallbackStart)
                        let fallbackStats = treeStats(fallbackTree)
                        printTreePhase(
                            "refresh \(refresh) cold fallback",
                            duration: fallbackDuration,
                            stats: fallbackStats
                        )

                        let saveStart = clock.now
                        try TreeCache.save(
                            tree: fallbackTree,
                            lastEventId: fallbackEventId
                        )
                        let saveDuration = elapsed(since: saveStart)
                        print(
                            "[real-volume warm bench] refresh \(refresh) cold cache save: "
                                + "\(formatSeconds(saveDuration)); "
                                + "cache=\(cacheSize(for: root).map(gibibytes) ?? "unavailable"); "
                                + "\(memoryDescription())"
                        )
                    }
                }

                if runRealVolumeWarmStartDiagnostics {
                    if !RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(
                        completedComparableDiagnosticWorkloads
                    ) {
                        Issue.record(
                            "diagnostic mode completed \(refreshAttemptLimit) production-planner refresh attempts but collected only \(completedComparableDiagnosticWorkloads) distinct comparable non-empty warm workloads; required \(RealVolumeDiagnosticPolicy.requiredWarmWorkloadCount)"
                        )
                    } else if let aggregateMedianImprovement =
                                RealVolumeDiagnosticTimingPolicy.median(
                                    balancedWorkloadImprovements
                                ) {
                        print(
                            "[real-volume warm bench] aggregate balanced diagnostic gate: "
                                + "comparable_workloads="
                                + "\(balancedWorkloadImprovements.count), "
                                + "median_relative_time_to_publication_saved="
                                + String(
                                    format: "%.2f%%",
                                    aggregateMedianImprovement * 100
                                )
                                + ", required="
                                + String(
                                    format: "%.2f%%",
                                    RealVolumeDiagnosticTimingPolicy
                                        .materialImprovementFloor * 100
                                )
                                + ", absolute_target=none"
                        )
                        #expect(
                            aggregateMedianImprovement
                                >= RealVolumeDiagnosticTimingPolicy
                                    .materialImprovementFloor,
                            "three-workload balanced median interactive publication improved only \(String(format: "%.2f%%", aggregateMedianImprovement * 100))"
                        )
                    } else {
                        Issue.record(
                            "diagnostic mode collected comparable workloads but produced no balanced aggregate effect"
                        )
                    }
                }
                print("[real-volume warm bench] END; \(memoryDescription())")
            }
#endif
        }
    }
}

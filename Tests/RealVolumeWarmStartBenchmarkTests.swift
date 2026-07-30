import Darwin
import Foundation
import Testing
@testable import DirWizCore

/// Deliberately stricter than the ordinary heavy-benchmark gate: a real-volume scan can
/// take minutes on a slow or very full disk and must never happen merely because someone
/// ran `swift test`. The exact opt-in is intentionally named in both the code and output.
private let runRealVolumeWarmStartBenchmark =
    ProcessInfo.processInfo.environment["DIRWIZ_REAL_VOLUME_BENCH"] == "1"

/// Optional diagnostic mode layered on top of the already explicit real-volume
/// benchmark opt-in. A warm decision is replayed three times from independent decodes of
/// the same pre-patch scratch cache, using the exact target list returned by that one
/// journal/planner decision. This is deliberately not implied by
/// `DIRWIZ_REAL_VOLUME_BENCH`: it makes an already expensive benchmark substantially
/// heavier.
private let runRealVolumeWarmStartDiagnostics =
    ProcessInfo.processInfo.environment["DIRWIZ_REAL_VOLUME_DIAGNOSTIC"] == "1"

/// Keeps the ordinary three-refresh benchmark unchanged while making the heavier
/// diagnostic mode honest about whether it actually observed a patchable workload.
private enum RealVolumeDiagnosticPolicy {
    static let ordinaryRefreshAttemptCount = 3
    static let requiredWarmWorkloadCount = 3
    static let samplesPerWarmWorkload = 3

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
        targetCount: Int
    ) -> Bool {
        diagnosticEnabled && targetCount > 0
    }

    static func hasRequiredWarmWorkloads(_ completedWorkloadCount: Int) -> Bool {
        completedWorkloadCount >= requiredWarmWorkloadCount
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

    @Test("Only non-empty diagnostic decisions count, and three workloads finish the gate")
    func collectionAndCompletion() {
        #expect(
            !RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: false,
                targetCount: 12
            )
        )
        #expect(
            !RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: true,
                targetCount: 0
            )
        )
        #expect(
            RealVolumeDiagnosticPolicy.shouldCollect(
                diagnosticEnabled: true,
                targetCount: 1
            )
        )
        #expect(!RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(2))
        #expect(RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(3))
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

        private struct TreeStats {
            let items: Int
            let directories: Int
            let files: Int
            let allocatedBytes: UInt64
        }

        private func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }

        private func elapsed(since start: ContinuousClock.Instant) -> Double {
            seconds(ContinuousClock().now - start)
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
            lhs.items == rhs.items
                && lhs.directories == rhs.directories
                && lhs.files == rhs.files
                && lhs.allocatedBytes == rhs.allocatedBytes
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
                var completedNonEmptyDiagnosticWorkloads = 0
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
                    "[real-volume warm bench] safety: no mutation of pre-existing root content; "
                        + "scratch cache only; bundle sizing disabled; immediate headless materialisation"
                )
                if runRealVolumeWarmStartDiagnostics {
                    print(
                        "[real-volume warm bench] diagnostic mode: three distinct non-empty "
                            + "production-planner warm decisions are required; each decision's "
                            + "target list is replayed from a fresh decode of the same pre-patch "
                            + "scratch cache for three repeat samples; "
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

                        let report: SubtreeRescanReport
                        let patchDuration: Double
                        if RealVolumeDiagnosticPolicy.shouldCollect(
                            diagnosticEnabled: runRealVolumeWarmStartDiagnostics,
                            targetCount: targets.count
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
                            var selectedPayload: TreeCache.Payload?
                            var selectedReport: SubtreeRescanReport?
                            var selectedDuration: Double?
                            var durations: [Double] = []
                            durations.reserveCapacity(Self.diagnosticPatchSampleCount)
                            var firstPatchedStats: TreeStats?
                            var patchedStatsMatch = true

                            for sample in 1...Self.diagnosticPatchSampleCount {
                                let diagnosticLoadStart = clock.now
                                guard let samplePayload = TreeCache.load(for: root) else {
                                    Issue.record(
                                        "refresh \(refresh) diagnostic sample \(sample): pre-patch scratch cache failed to reload"
                                    )
                                    return
                                }
                                let diagnosticLoadDuration = elapsed(since: diagnosticLoadStart)
                                let sampleBaselineStats = treeStats(samplePayload.tree)
                                guard samplePayload.lastEventId == prePatchEventId,
                                      sampleBaselineStats.items == prePatchStats.items,
                                      sampleBaselineStats.directories == prePatchStats.directories,
                                      sampleBaselineStats.files == prePatchStats.files,
                                      sampleBaselineStats.allocatedBytes
                                        == prePatchStats.allocatedBytes else {
                                    Issue.record(
                                        "refresh \(refresh) diagnostic sample \(sample): scratch cache did not reload the same pre-patch baseline"
                                    )
                                    return
                                }
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic "
                                        + "sample \(sample) cache reload: "
                                        + "\(formatSeconds(diagnosticLoadDuration)); "
                                        + "event_id=\(samplePayload.lastEventId), "
                                        + "items=\(sampleBaselineStats.items), "
                                        + "dirs=\(sampleBaselineStats.directories)"
                                )

                                // Compute the exact same cached-tree estimate that guards
                                // production warm starts, one root at a time. Keep this
                                // outside `diagnosticPatchStart`: estimate lookup is
                                // diagnostic overhead, not patch time.
                                let sampleRootEstimates = perRootCachedEstimates(
                                    for: diagnosticTargets,
                                    cachedTree: samplePayload.tree
                                )
                                let resourcesBefore = processResourceSample()
                                let diagnosticPatchStart = clock.now
                                let sampleReport = await FileScanner(
                                    computeBundleSizes: false,
                                    deferTreeMaterialization: false
                                ).rescanSubtrees(
                                    diagnosticTargets,
                                    tree: samplePayload.tree,
                                    progress: ScanProgress()
                                )
                                let sampleDuration = elapsed(since: diagnosticPatchStart)
                                let resourcesAfter = processResourceSample()
                                durations.append(sampleDuration)

                                let samplePatchedStats = treeStats(samplePayload.tree)
                                if let firstPatchedStats {
                                    if !sameTreeStats(samplePatchedStats, firstPatchedStats) {
                                        patchedStatsMatch = false
                                    }
                                } else {
                                    firstPatchedStats = samplePatchedStats
                                }
                                printTreePhase(
                                    "refresh \(refresh) diagnostic sample \(sample) warm patch "
                                        + "(requested=\(sampleReport.requestedPaths.count), "
                                        + "rescanned=\(sampleReport.rescannedRoots.count), "
                                        + "unresolved=\(sampleReport.unresolvedPaths.count), "
                                        + "cancelled=\(sampleReport.wasCancelled))",
                                    duration: sampleDuration,
                                    stats: samplePatchedStats
                                )
                                printRescanMetrics(
                                    sampleReport.metrics,
                                    prefix: "refresh \(refresh) diagnostic sample \(sample)"
                                )
                                let sampleDistribution =
                                    printRootStagingDistribution(
                                        sampleReport.metrics.rootStaging,
                                        estimatedItemsByPath: sampleRootEstimates,
                                        prefix:
                                            "refresh \(refresh) diagnostic sample \(sample)"
                                    )
                                validateRootStagingEstimates(
                                    sampleDistribution,
                                    expectedPatchItems: estimatedPatchItems,
                                    prefix:
                                        "refresh \(refresh) diagnostic sample \(sample)"
                                )
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic "
                                        + "sample \(sample) resources: "
                                        + resourceDeltaDescription(
                                            before: resourcesBefore,
                                            after: resourcesAfter
                                        )
                                )

                                guard sampleReport.unresolvedPaths.isEmpty,
                                      !sampleReport.rescannedRoots.contains(root),
                                      !sampleReport.wasCancelled else {
                                    Issue.record(
                                        "refresh \(refresh) diagnostic sample \(sample): warm patch was incomplete"
                                    )
                                    return
                                }

                                // Only the final independently loaded sample becomes the
                                // production-equivalent result saved below. Earlier
                                // sample trees fall out of scope without ever touching
                                // the pre-patch cache.
                                if sample == Self.diagnosticPatchSampleCount {
                                    selectedPayload = samplePayload
                                    selectedReport = sampleReport
                                    selectedDuration = sampleDuration
                                }
                            }

                            guard let selectedPayload,
                                  let selectedReport,
                                  let selectedDuration else {
                                Issue.record(
                                    "refresh \(refresh): diagnostic samples produced no final tree"
                                )
                                return
                            }
                            payload = selectedPayload
                            report = selectedReport
                            patchDuration = selectedDuration
                            // One completed workload means one distinct non-empty planner
                            // decision/FSEvents replay window. The three repeats above
                            // characterize that ONE workload and never count as three
                            // independent decisions.
                            completedNonEmptyDiagnosticWorkloads += 1

                            let orderedDurations = durations.sorted()
                            let medianDuration =
                                orderedDurations[orderedDurations.count / 2]
                            if patchedStatsMatch {
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic summary: "
                                        + "samples=\(durations.count), comparable=true, "
                                        + "min=\(formatSeconds(orderedDurations.first!)), "
                                        + "median=\(formatSeconds(medianDuration)), "
                                        + "max=\(formatSeconds(orderedDurations.last!))"
                                )
                            } else {
                                print(
                                    "[real-volume warm bench] refresh \(refresh) diagnostic summary: "
                                        + "samples=\(durations.count), comparable=false, "
                                        + "median=refused because patched tree stats changed "
                                        + "between samples (live-filesystem drift); "
                                        + "min_observed=\(formatSeconds(orderedDurations.first!)), "
                                        + "max_observed=\(formatSeconds(orderedDurations.last!))"
                                )
                            }
                        } else {
                            // As above, keep cached-tree estimate lookup out of the warm
                            // patch's measured interval.
                            let rootEstimates = perRootCachedEstimates(
                                for: targets,
                                cachedTree: payload!.tree
                            )
                            let patchStart = clock.now
                            report = await FileScanner(
                                computeBundleSizes: false,
                                deferTreeMaterialization: false
                            ).rescanSubtrees(
                                targets,
                                tree: payload!.tree,
                                progress: ScanProgress()
                            )
                            patchDuration = elapsed(since: patchStart)
                            let distribution = printRootStagingDistribution(
                                report.metrics.rootStaging,
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
                                + "(requested=\(report.requestedPaths.count), "
                                + "rescanned=\(report.rescannedRoots.count), "
                                + "unresolved=\(report.unresolvedPaths.count), "
                                + "cancelled=\(report.wasCancelled))",
                            duration: patchDuration,
                            stats: patchedStats
                        )
                        if !runRealVolumeWarmStartDiagnostics {
                            printRescanMetrics(
                                report.metrics,
                                prefix: "refresh \(refresh) warm patch"
                            )
                        }

                        guard report.unresolvedPaths.isEmpty,
                              !report.rescannedRoots.contains(root),
                              !report.wasCancelled else {
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
                               completedNonEmptyDiagnosticWorkloads
                           ) {
                            print(
                                "[real-volume warm bench] diagnostic collection complete: "
                                    + "completed_non_empty_workloads="
                                    + "\(completedNonEmptyDiagnosticWorkloads), "
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

                if runRealVolumeWarmStartDiagnostics,
                   !RealVolumeDiagnosticPolicy.hasRequiredWarmWorkloads(
                       completedNonEmptyDiagnosticWorkloads
                   ) {
                    Issue.record(
                        "diagnostic mode completed \(refreshAttemptLimit) production-planner refresh attempts but collected only \(completedNonEmptyDiagnosticWorkloads) distinct non-empty warm workloads; required \(RealVolumeDiagnosticPolicy.requiredWarmWorkloadCount)"
                    )
                }
                print("[real-volume warm bench] END; \(memoryDescription())")
            }
#endif
        }
    }
}

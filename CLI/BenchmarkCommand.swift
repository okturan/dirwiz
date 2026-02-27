import Foundation
import DirWizLib

private struct BenchmarkIterationReport {
    let iteration: Int
    let scanSeconds: Double
    let scanEstimate: ScanEstimateAccuracyReport
    let duplicateSeconds: Double
    let duplicateGroups: Int
    let duplicateProgress: DuplicateProgressReliabilityReport
    let hardlinkSeconds: Double
    let hardlinkGroups: Int
    let hardlinkProgress: DeterminateProgressReport
    let analysisSeconds: Double
    let categoryCount: Int
    let fileAgeBucketCount: Int
    let sizeBucketCount: Int
}

private struct TimingSummary {
    let mean: Double
    let min: Double
    let max: Double
}

@MainActor
private final class DuplicateProgressRecorder {
    var samples: [TimedDuplicateProgressSample] = []

    func record(_ update: DuplicateScanUpdate, startTime: CFAbsoluteTime) {
        samples.append(TimedDuplicateProgressSample(
            phase: update.phase,
            processed: update.processed,
            total: update.total,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime
        ))
    }
}

@MainActor
private final class DeterminateProgressRecorder {
    var samples: [TimedProgressSample] = []

    func record(processed: Int, total: Int, startTime: CFAbsoluteTime) {
        samples.append(TimedProgressSample(
            processed: processed,
            total: total,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - startTime
        ))
    }
}

extension DirWizCLI {
    static func handleBenchmark(args: [String]) async {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            errPrint("Error: benchmark requires a path argument")
            exit(1)
        }

        let iterations = max(parseInt("--iterations", from: args) ?? 3, 1)
        let outputJSON = args.contains("--json")
        let quiet = args.contains("--quiet") || args.contains("-q")

        var reports: [BenchmarkIterationReport] = []
        reports.reserveCapacity(iterations)

        for iteration in 1...iterations {
            if !quiet {
                errPrint("Benchmark iteration \(iteration)/\(iterations): \(path)")
            }
            let report = await runBenchmarkIteration(path: path, iteration: iteration)
            reports.append(report)
            if !quiet && !outputJSON {
                printIterationReport(report)
            }
        }

        if outputJSON {
            printBenchmarkJSON(reports)
        } else {
            printBenchmarkSummary(reports)
        }
    }

    private static func runBenchmarkIteration(path: String, iteration: Int) async -> BenchmarkIterationReport {
        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()

        let scanStart = CFAbsoluteTimeGetCurrent()
        await scanner.scan(path: path, progress: progress, tree: tree)
        let scanSeconds = CFAbsoluteTimeGetCurrent() - scanStart
        let scanEstimate = await MainActor.run {
            BenchmarkTelemetry.analyzeScanEstimate(
                estimatedTotalItems: progress.estimatedTotalItems,
                actualTotalItems: progress.totalItems
            )
        }

        let duplicateRecorder = await MainActor.run { DuplicateProgressRecorder() }
        let duplicateFinder = DuplicateFinder()
        let duplicateStart = CFAbsoluteTimeGetCurrent()
        let duplicateGroups = await duplicateFinder.findDuplicates(in: tree) { update in
            duplicateRecorder.record(update, startTime: duplicateStart)
        }
        let duplicateSeconds = CFAbsoluteTimeGetCurrent() - duplicateStart
        let duplicateProgress = await MainActor.run {
            BenchmarkTelemetry.analyzeDuplicateProgress(samples: duplicateRecorder.samples)
        }

        let hardlinkRecorder = await MainActor.run { DeterminateProgressRecorder() }
        let hardlinkFinder = HardlinkFinder()
        let hardlinkStart = CFAbsoluteTimeGetCurrent()
        let hardlinkGroups = await hardlinkFinder.findHardlinks(in: tree) { processed, total in
            hardlinkRecorder.record(processed: processed, total: total, startTime: hardlinkStart)
        }
        let hardlinkSeconds = CFAbsoluteTimeGetCurrent() - hardlinkStart
        let hardlinkProgress = await MainActor.run {
            BenchmarkTelemetry.analyzeDeterminateProgress(samples: hardlinkRecorder.samples)
        }

        let analysisStart = CFAbsoluteTimeGetCurrent()
        async let space = SpaceAnalyzer().analyze(tree: tree)
        async let fileAge = FileAgeAnalyzer().analyze(tree: tree)
        async let sizeDistribution = SizeDistributionAnalyzer().analyze(tree: tree)
        let (spaceResult, fileAgeResult, sizeDistributionResult) = await (space, fileAge, sizeDistribution)
        let analysisSeconds = CFAbsoluteTimeGetCurrent() - analysisStart

        return BenchmarkIterationReport(
            iteration: iteration,
            scanSeconds: scanSeconds,
            scanEstimate: scanEstimate,
            duplicateSeconds: duplicateSeconds,
            duplicateGroups: duplicateGroups.count,
            duplicateProgress: duplicateProgress,
            hardlinkSeconds: hardlinkSeconds,
            hardlinkGroups: hardlinkGroups.count,
            hardlinkProgress: hardlinkProgress,
            analysisSeconds: analysisSeconds,
            categoryCount: spaceResult.categories.count,
            fileAgeBucketCount: fileAgeResult.buckets.count,
            sizeBucketCount: sizeDistributionResult.buckets.count
        )
    }

    private static func printIterationReport(_ report: BenchmarkIterationReport) {
        print("Iteration \(report.iteration)")
        print("  scan:       \(formatSeconds(report.scanSeconds))  estimate \(formatEstimate(report.scanEstimate))")
        let dupPhaseDetails = report.duplicateProgress.phases.map { phase -> String in
            let p = phase.progress
            let firstNZ = p.firstNonZeroProcessedItems.map { "\($0)/\(p.total)" } ?? "n/a"
            let phaseStart = p.firstSampleSeconds.map { String(format: "%.3fs", $0) } ?? "n/a"
            let firstNZTime = p.firstNonZeroSeconds.map { String(format: "%.3fs", $0) } ?? "n/a"
            let stuckDuration: String
            if let start = p.firstSampleSeconds, let nonZero = p.firstNonZeroSeconds {
                stuckDuration = String(format: "%.3fs", nonZero - start)
            } else {
                stuckDuration = "n/a"
            }
            return "    \(phase.phase): first-nonzero \(firstNZ)  stuck-at-0 \(stuckDuration)  phase-start \(phaseStart)  samples \(p.sampleCount)"
        }.joined(separator: "\n")
        print("  duplicates: \(formatSeconds(report.duplicateSeconds))  groups \(report.duplicateGroups)  monotonic \(yesNo(report.duplicateProgress.allPhasesMonotonic))  hashing-starts-zero \(yesNo(report.duplicateProgress.hashingPhasesStartedAtZero))")
        print(dupPhaseDetails)
        print("  hardlinks:  \(formatSeconds(report.hardlinkSeconds))  groups \(report.hardlinkGroups)  monotonic \(yesNo(report.hardlinkProgress.monotonicProcessed))  completed \(yesNo(report.hardlinkProgress.completed))")
        print("  insights:   \(formatSeconds(report.analysisSeconds))  categories \(report.categoryCount)  age-buckets \(report.fileAgeBucketCount)  size-buckets \(report.sizeBucketCount)")
        print()
    }

    private static func printBenchmarkSummary(_ reports: [BenchmarkIterationReport]) {
        guard !reports.isEmpty else { return }
        print("Benchmark Summary")
        print("  scan:       \(formatSummary(summarize(reports.map(\.scanSeconds))))")
        print("  duplicates: \(formatSummary(summarize(reports.map(\.duplicateSeconds))))")
        print("  hardlinks:  \(formatSummary(summarize(reports.map(\.hardlinkSeconds))))")
        print("  insights:   \(formatSummary(summarize(reports.map(\.analysisSeconds))))")

        let determinateEstimates = reports.compactMap { report -> Double? in
            guard report.scanEstimate.estimatedTotalItems > 0 else { return nil }
            return report.scanEstimate.relativeError
        }
        if determinateEstimates.isEmpty {
            print("  scan-estimate avg relative error: indeterminate for all iterations")
        } else {
            let avgEstimateError = determinateEstimates.reduce(0, +) / Double(determinateEstimates.count)
            print("  scan-estimate avg relative error: \(String(format: "%.2fx", avgEstimateError))")
        }
        print("  duplicate phases monotonic: \(yesNo(reports.allSatisfy { $0.duplicateProgress.allPhasesMonotonic }))")
        print("  duplicate hashing starts at zero: \(yesNo(reports.allSatisfy { $0.duplicateProgress.hashingPhasesStartedAtZero }))")
        print("  hardlink progress completed: \(yesNo(reports.allSatisfy { $0.hardlinkProgress.completed }))")
    }

    private static func printBenchmarkJSON(_ reports: [BenchmarkIterationReport]) {
        let jsonObject: [String: Any] = [
            "iterations": reports.map { report in
                [
                    "iteration": report.iteration,
                    "scanSeconds": report.scanSeconds,
                    "scanEstimate": [
                        "hasEstimate": report.scanEstimate.estimatedTotalItems > 0,
                        "estimatedTotalItems": report.scanEstimate.estimatedTotalItems,
                        "actualTotalItems": report.scanEstimate.actualTotalItems,
                        "direction": report.scanEstimate.direction.rawValue,
                        "absoluteError": report.scanEstimate.absoluteError,
                        "relativeError": report.scanEstimate.relativeError as Any,
                    ],
                    "duplicates": [
                        "seconds": report.duplicateSeconds,
                        "groups": report.duplicateGroups,
                        "allPhasesMonotonic": report.duplicateProgress.allPhasesMonotonic,
                        "allPhaseTotalsStable": report.duplicateProgress.allPhaseTotalsStable,
                        "hashingPhasesStartedAtZero": report.duplicateProgress.hashingPhasesStartedAtZero,
                    ],
                    "hardlinks": [
                        "seconds": report.hardlinkSeconds,
                        "groups": report.hardlinkGroups,
                        "startedAtZero": report.hardlinkProgress.startedAtZero,
                        "monotonicProcessed": report.hardlinkProgress.monotonicProcessed,
                        "totalStable": report.hardlinkProgress.totalStable,
                        "completed": report.hardlinkProgress.completed,
                    ],
                    "insights": [
                        "seconds": report.analysisSeconds,
                        "categoryCount": report.categoryCount,
                        "fileAgeBucketCount": report.fileAgeBucketCount,
                        "sizeBucketCount": report.sizeBucketCount,
                    ],
                ]
            }
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } catch {
            errPrint("Error encoding benchmark JSON: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func summarize(_ values: [Double]) -> TimingSummary {
        guard let min = values.min(), let max = values.max(), !values.isEmpty else {
            return TimingSummary(mean: 0, min: 0, max: 0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return TimingSummary(mean: mean, min: min, max: max)
    }

    private static func formatSummary(_ summary: TimingSummary) -> String {
        "mean \(formatSeconds(summary.mean))  min \(formatSeconds(summary.min))  max \(formatSeconds(summary.max))"
    }

    private static func formatEstimate(_ report: ScanEstimateAccuracyReport) -> String {
        guard report.estimatedTotalItems > 0 else {
            return "indeterminate"
        }
        guard let relative = report.relativeError else {
            return "n/a"
        }
        return "\(report.direction.rawValue) \(String(format: "%.2fx", relative))"
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

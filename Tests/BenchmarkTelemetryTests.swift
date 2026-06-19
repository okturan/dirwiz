import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

@Suite("Benchmark Telemetry Tests")
struct BenchmarkTelemetryTests {
    @Test("determinate progress report captures monotonic completion")
    func determinateProgressReportCapturesCompletion() {
        let report = BenchmarkTelemetry.analyzeDeterminateProgress(samples: [
            TimedProgressSample(processed: 0, total: 10, elapsedSeconds: 0.01),
            TimedProgressSample(processed: 4, total: 10, elapsedSeconds: 0.10),
            TimedProgressSample(processed: 10, total: 10, elapsedSeconds: 0.25),
        ])

        #expect(report.sampleCount == 3)
        #expect(report.startedAtZero)
        #expect(report.monotonicProcessed)
        #expect(report.totalStable)
        #expect(report.completed)
        #expect(report.firstNonZeroSeconds == 0.10)
        #expect(report.largestGapSeconds >= 0.09)
    }

    @Test("duplicate progress report checks phase behavior")
    func duplicateProgressReportChecksPhaseBehavior() {
        let report = BenchmarkTelemetry.analyzeDuplicateProgress(samples: [
            TimedDuplicateProgressSample(phase: .groupingBySize, processed: 10, total: 10, elapsedSeconds: 0.01),
            TimedDuplicateProgressSample(phase: .partialHashing, processed: 0, total: 6, elapsedSeconds: 0.02),
            TimedDuplicateProgressSample(phase: .partialHashing, processed: 6, total: 6, elapsedSeconds: 0.05),
            TimedDuplicateProgressSample(phase: .fullHashing, processed: 0, total: 4, elapsedSeconds: 0.06),
            TimedDuplicateProgressSample(phase: .fullHashing, processed: 4, total: 4, elapsedSeconds: 0.09),
            TimedDuplicateProgressSample(phase: .finalizing, processed: 1, total: 1, elapsedSeconds: 0.10),
        ])

        #expect(report.allPhasesMonotonic)
        #expect(report.allPhaseTotalsStable)
        #expect(report.hashingPhasesStartedAtZero)
        #expect(report.phases.count == 4)
    }

    @Test("scan estimate report describes over-estimate")
    func scanEstimateReportDescribesOverEstimate() {
        let report = BenchmarkTelemetry.analyzeScanEstimate(
            estimatedTotalItems: 500,
            actualTotalItems: 125
        )

        #expect(report.direction == .overEstimate)
        #expect(report.absoluteError == 375)
        #expect(report.relativeError == 3.0)
    }
}

import Foundation

public struct ScanEstimateAccuracyReport: Sendable {
    public enum Direction: String, Sendable {
        case exact
        case underEstimate
        case overEstimate
    }

    public let estimatedTotalItems: Int
    public let actualTotalItems: Int
    public let direction: Direction
    public let absoluteError: Int
    public let relativeError: Double?

    public init(
        estimatedTotalItems: Int,
        actualTotalItems: Int,
        direction: Direction,
        absoluteError: Int,
        relativeError: Double?
    ) {
        self.estimatedTotalItems = estimatedTotalItems
        self.actualTotalItems = actualTotalItems
        self.direction = direction
        self.absoluteError = absoluteError
        self.relativeError = relativeError
    }
}

public struct TimedProgressSample: Sendable {
    public let processed: Int
    public let total: Int
    public let elapsedSeconds: TimeInterval

    public init(processed: Int, total: Int, elapsedSeconds: TimeInterval) {
        self.processed = processed
        self.total = total
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct DeterminateProgressReport: Sendable {
    public let sampleCount: Int
    public let total: Int
    public let startedAtZero: Bool
    public let monotonicProcessed: Bool
    public let totalStable: Bool
    public let completed: Bool
    public let firstSampleSeconds: TimeInterval?
    public let firstNonZeroSeconds: TimeInterval?
    public let firstNonZeroProcessedItems: Int?
    public let largestGapSeconds: TimeInterval
    /// Max items processed in a single progress jump (measures batch granularity).
    public let largestProcessedJump: Int

    public init(
        sampleCount: Int,
        total: Int,
        startedAtZero: Bool,
        monotonicProcessed: Bool,
        totalStable: Bool,
        completed: Bool,
        firstSampleSeconds: TimeInterval?,
        firstNonZeroSeconds: TimeInterval?,
        firstNonZeroProcessedItems: Int?,
        largestGapSeconds: TimeInterval,
        largestProcessedJump: Int
    ) {
        self.sampleCount = sampleCount
        self.total = total
        self.startedAtZero = startedAtZero
        self.monotonicProcessed = monotonicProcessed
        self.totalStable = totalStable
        self.completed = completed
        self.firstSampleSeconds = firstSampleSeconds
        self.firstNonZeroSeconds = firstNonZeroSeconds
        self.firstNonZeroProcessedItems = firstNonZeroProcessedItems
        self.largestGapSeconds = largestGapSeconds
        self.largestProcessedJump = largestProcessedJump
    }
}

public struct TimedDuplicateProgressSample: Sendable {
    public let phase: DuplicateScanPhase
    public let processed: Int
    public let total: Int
    public let elapsedSeconds: TimeInterval

    public init(
        phase: DuplicateScanPhase,
        processed: Int,
        total: Int,
        elapsedSeconds: TimeInterval
    ) {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct DuplicatePhaseProgressReport: Sendable {
    public let phase: DuplicateScanPhase
    public let progress: DeterminateProgressReport

    public init(phase: DuplicateScanPhase, progress: DeterminateProgressReport) {
        self.phase = phase
        self.progress = progress
    }
}

public struct DuplicateProgressReliabilityReport: Sendable {
    public let phases: [DuplicatePhaseProgressReport]

    public init(phases: [DuplicatePhaseProgressReport]) {
        self.phases = phases
    }

    public var allPhasesMonotonic: Bool {
        phases.allSatisfy { $0.progress.monotonicProcessed }
    }

    public var allPhaseTotalsStable: Bool {
        phases.allSatisfy { $0.progress.totalStable }
    }

    public var hashingPhasesStartedAtZero: Bool {
        let hashing = phases.filter { $0.phase == .partialHashing || $0.phase == .fullHashing }
        guard !hashing.isEmpty else { return true }
        return hashing.allSatisfy { $0.progress.startedAtZero }
    }
}

public enum BenchmarkTelemetry {
    public static func analyzeScanEstimate(
        estimatedTotalItems: Int,
        actualTotalItems: Int
    ) -> ScanEstimateAccuracyReport {
        let absoluteError = abs(estimatedTotalItems - actualTotalItems)
        let direction: ScanEstimateAccuracyReport.Direction
        if estimatedTotalItems == actualTotalItems {
            direction = .exact
        } else if estimatedTotalItems < actualTotalItems {
            direction = .underEstimate
        } else {
            direction = .overEstimate
        }

        let relativeError: Double?
        if actualTotalItems > 0 {
            relativeError = Double(absoluteError) / Double(actualTotalItems)
        } else {
            relativeError = nil
        }

        return ScanEstimateAccuracyReport(
            estimatedTotalItems: estimatedTotalItems,
            actualTotalItems: actualTotalItems,
            direction: direction,
            absoluteError: absoluteError,
            relativeError: relativeError
        )
    }

    public static func analyzeDeterminateProgress(
        samples: [TimedProgressSample]
    ) -> DeterminateProgressReport {
        guard let first = samples.first else {
            return DeterminateProgressReport(
                sampleCount: 0,
                total: 0,
                startedAtZero: false,
                monotonicProcessed: true,
                totalStable: true,
                completed: false,
                firstSampleSeconds: nil,
                firstNonZeroSeconds: nil,
                firstNonZeroProcessedItems: nil,
                largestGapSeconds: 0,
                largestProcessedJump: 0
            )
        }

        var monotonicProcessed = true
        var totalStable = true
        var largestGapSeconds: TimeInterval = 0
        var largestProcessedJump = 0
        var previous = first
        for sample in samples.dropFirst() {
            if sample.processed < previous.processed {
                monotonicProcessed = false
            }
            if sample.total != previous.total {
                totalStable = false
            }
            largestGapSeconds = max(largestGapSeconds, sample.elapsedSeconds - previous.elapsedSeconds)
            largestProcessedJump = max(largestProcessedJump, sample.processed - previous.processed)
            previous = sample
        }

        let total = samples.last?.total ?? 0
        let completed = total > 0 && (samples.last?.processed ?? 0) >= total
        let firstNonZero = samples.first(where: { $0.processed > 0 })

        return DeterminateProgressReport(
            sampleCount: samples.count,
            total: total,
            startedAtZero: first.processed == 0,
            monotonicProcessed: monotonicProcessed,
            totalStable: totalStable,
            completed: completed,
            firstSampleSeconds: first.elapsedSeconds,
            firstNonZeroSeconds: firstNonZero?.elapsedSeconds,
            firstNonZeroProcessedItems: firstNonZero?.processed,
            largestGapSeconds: largestGapSeconds,
            largestProcessedJump: largestProcessedJump
        )
    }

    public static func analyzeDuplicateProgress(
        samples: [TimedDuplicateProgressSample]
    ) -> DuplicateProgressReliabilityReport {
        var grouped: [DuplicateScanPhase: [TimedProgressSample]] = [:]
        for sample in samples {
            grouped[sample.phase, default: []].append(TimedProgressSample(
                processed: sample.processed,
                total: sample.total,
                elapsedSeconds: sample.elapsedSeconds
            ))
        }

        let phases = grouped.keys.sorted(by: phaseOrder)
        let reports = phases.map { phase in
            DuplicatePhaseProgressReport(
                phase: phase,
                progress: analyzeDeterminateProgress(samples: grouped[phase] ?? [])
            )
        }

        return DuplicateProgressReliabilityReport(phases: reports)
    }

    private static func phaseOrder(_ lhs: DuplicateScanPhase, _ rhs: DuplicateScanPhase) -> Bool {
        phaseRank(lhs) < phaseRank(rhs)
    }

    private static func phaseRank(_ phase: DuplicateScanPhase) -> Int {
        switch phase {
        case .groupingBySize:
            return 0
        case .partialHashing:
            return 1
        case .fullHashing:
            return 2
        case .finalizing:
            return 3
        }
    }
}

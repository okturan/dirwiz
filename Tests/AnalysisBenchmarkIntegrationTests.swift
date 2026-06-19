import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

@Suite("Analysis Benchmark Integration Tests")
struct AnalysisBenchmarkIntegrationTests {
    @MainActor
    @Test("duplicate benchmark telemetry stays monotonic on real fixture")
    func duplicateBenchmarkTelemetryStaysMonotonic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizDupBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let duplicateData = Data(repeating: 0xA5, count: 128 * 1024)
        try duplicateData.write(to: root.appendingPathComponent("dup-a.bin"))
        try duplicateData.write(to: root.appendingPathComponent("dup-b.bin"))
        try duplicateData.write(to: root.appendingPathComponent("dup-c.bin"))
        try Data(repeating: 0x5A, count: 128 * 1024).write(to: root.appendingPathComponent("unique.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dup-link"),
            withDestinationURL: root.appendingPathComponent("dup-a.bin")
        )

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: root.path, progress: progress, tree: tree)

        var samples: [TimedDuplicateProgressSample] = []
        let start = CFAbsoluteTimeGetCurrent()
        let groups = await DuplicateFinder().findDuplicates(in: tree) { update in
            samples.append(TimedDuplicateProgressSample(
                phase: update.phase,
                processed: update.processed,
                total: update.total,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start
            ))
        }

        let report = BenchmarkTelemetry.analyzeDuplicateProgress(samples: samples)
        #expect(!groups.isEmpty)
        #expect(report.allPhasesMonotonic)
        #expect(report.allPhaseTotalsStable)
        #expect(report.hashingPhasesStartedAtZero)
    }

    /// Regression test: progress uses a GCD timer that fires every 250ms,
    /// decoupled from the cooperative pool. With tiny test files on fast SSD,
    /// all tasks may complete within one timer tick, so we only verify the
    /// progress callback fires at least once for the hashing phase.
    /// Real-world coverage is validated by the benchmark CLI on actual data.
    @MainActor
    @Test("duplicate progress reports hashing phase")
    func duplicateProgressReportsHashingPhase() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizBatchBound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let content = Data(repeating: 0xBB, count: 4096)
        for i in 0..<64 {
            try content.write(to: root.appendingPathComponent("dup-\(String(format: "%04d", i)).bin"))
        }

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: root.path, progress: progress, tree: tree)

        var samples: [TimedDuplicateProgressSample] = []
        let start = CFAbsoluteTimeGetCurrent()
        let groups = await DuplicateFinder().findDuplicates(in: tree) { update in
            samples.append(TimedDuplicateProgressSample(
                phase: update.phase,
                processed: update.processed,
                total: update.total,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start
            ))
        }

        #expect(!groups.isEmpty, "Should find duplicates")
        let report = BenchmarkTelemetry.analyzeDuplicateProgress(samples: samples)
        #expect(report.allPhasesMonotonic, "All phases should be monotonic")
        #expect(report.hashingPhasesStartedAtZero, "Hashing phases should start at zero")
        let hasHashPhase = report.phases.contains { $0.phase == .partialHashing || $0.phase == .fullHashing }
        #expect(hasHashPhase, "Should report at least one hashing phase")
    }

    @MainActor
    @Test("hardlink benchmark telemetry completes on real fixture")
    func hardlinkBenchmarkTelemetryCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizHardlinkBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0xCC, count: 32 * 1024).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link-1.bin"))
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("link-2.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("skip-link"),
            withDestinationURL: original
        )

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: root.path, progress: progress, tree: tree)

        var samples: [TimedProgressSample] = []
        let start = CFAbsoluteTimeGetCurrent()
        let groups = await HardlinkFinder().findHardlinks(in: tree) { processed, total in
            samples.append(TimedProgressSample(
                processed: processed,
                total: total,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start
            ))
        }

        let report = BenchmarkTelemetry.analyzeDeterminateProgress(samples: samples)
        #expect(!groups.isEmpty)
        #expect(report.startedAtZero)
        #expect(report.monotonicProcessed)
        #expect(report.totalStable)
        #expect(report.completed)
    }
}

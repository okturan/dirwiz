import Testing
import Foundation
@testable import DirWizCore

/// Coverage for `WarmStartHistory` (warm-start-observability): a capped, per-volume,
/// plain-JSON history — deliberately NOT held to `TreeCache`'s fail-closed binary
/// discipline, since losing this diagnostic history costs nothing functionally.
///
/// Nested under `AppSupportEnvSuites` (TestHelpers.swift): every test here reads
/// `DIRWIZ_APP_SUPPORT_DIR` via `withTemporaryAppSupportDir`.
extension AppSupportEnvSuites {

@Suite("WarmStartHistory Tests")
struct WarmStartHistoryTests {

    private func entry(
        wasWarm: Bool, reason: String? = nil, itemCount: Int = 100, elapsedSeconds: Double = 1.0
    ) -> WarmStartHistory.Entry {
        .init(date: Date(), wasWarm: wasWarm, reason: reason, itemCount: itemCount, elapsedSeconds: elapsedSeconds)
    }

    @Test("Round-trip preserves every field")
    func roundTripPreservesFields() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/round-trip-fixture"
            let e = entry(wasWarm: false, reason: "cache file was corrupted", itemCount: 4_205_905, elapsedSeconds: 20.3)
            WarmStartHistory.record(e, for: path)

            let loaded = WarmStartHistory.load(for: path)
            #expect(loaded.count == 1)
            #expect(loaded.first?.wasWarm == false)
            #expect(loaded.first?.reason == "cache file was corrupted")
            #expect(loaded.first?.itemCount == 4_205_905)
            #expect(loaded.first?.elapsedSeconds == 20.3)
        }
    }

    @Test("A warm entry carries no reason")
    func warmEntryHasNoReason() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/warm-fixture"
            WarmStartHistory.record(entry(wasWarm: true), for: path)

            let loaded = WarmStartHistory.load(for: path)
            #expect(loaded.first?.wasWarm == true)
            #expect(loaded.first?.reason == nil)
        }
    }

    @Test("Entries accumulate in append order")
    func entriesAccumulateInOrder() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/accumulate-fixture"
            WarmStartHistory.record(entry(wasWarm: false, reason: "first"), for: path)
            WarmStartHistory.record(entry(wasWarm: true), for: path)
            WarmStartHistory.record(entry(wasWarm: false, reason: "third"), for: path)

            let loaded = WarmStartHistory.load(for: path)
            #expect(loaded.count == 3)
            #expect(loaded[0].reason == "first")
            #expect(loaded[1].wasWarm == true)
            #expect(loaded[2].reason == "third")
        }
    }

    @Test("Cap evicts the oldest entries first")
    func capEvictsOldestFirst() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/cap-fixture"
            let total = WarmStartHistory.maxEntries + 7
            for i in 0..<total {
                WarmStartHistory.record(entry(wasWarm: false, reason: "reason-\(i)"), for: path)
            }

            let loaded = WarmStartHistory.load(for: path)
            #expect(loaded.count == WarmStartHistory.maxEntries)
            // The oldest 7 (reason-0 through reason-6) must be gone; the newest
            // maxEntries survive, oldest-surviving-first.
            #expect(loaded.first?.reason == "reason-7")
            #expect(loaded.last?.reason == "reason-\(total - 1)")
        }
    }

    @Test("A missing file reads as empty history, not an error")
    func missingFileReadsAsEmpty() async throws {
        try await withTemporaryAppSupportDir {
            #expect(WarmStartHistory.load(for: "/never-recorded") == [])
        }
    }

    @Test("A malformed file degrades to empty history instead of crashing")
    func malformedFileDegradesToEmpty() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/malformed-fixture"
            WarmStartHistory.record(entry(wasWarm: true), for: path)
            #expect(WarmStartHistory.load(for: path).count == 1)

            // Overwrite with garbage bytes that aren't valid JSON at all.
            let env = ProcessInfo.processInfo.environment["DIRWIZ_APP_SUPPORT_DIR"]!
            let url = URL(fileURLWithPath: env)
                .appendingPathComponent("DirWiz/WarmStartHistory")
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            try #require(files.count == 1, "expected exactly one history file for this fixture")
            try Data("not json at all { [ garbage".utf8).write(to: files[0])

            #expect(WarmStartHistory.load(for: path) == [],
                "a malformed file must read as empty, not crash or throw")
        }
    }

    @Test("Different volumes get isolated histories")
    func differentVolumesAreIsolated() async throws {
        try await withTemporaryAppSupportDir {
            let pathA = "/volume-a"
            let pathB = "/volume-b"
            WarmStartHistory.record(entry(wasWarm: false, reason: "a-reason"), for: pathA)
            WarmStartHistory.record(entry(wasWarm: true), for: pathB)
            WarmStartHistory.record(entry(wasWarm: true), for: pathB)

            #expect(WarmStartHistory.load(for: pathA).count == 1)
            #expect(WarmStartHistory.load(for: pathA).first?.reason == "a-reason")
            #expect(WarmStartHistory.load(for: pathB).count == 2)
        }
    }

    @Test("clear removes a volume's history file")
    func clearRemovesHistory() async throws {
        try await withTemporaryAppSupportDir {
            let path = "/clear-fixture"
            WarmStartHistory.record(entry(wasWarm: true), for: path)
            #expect(WarmStartHistory.load(for: path).count == 1)

            WarmStartHistory.clear(for: path)
            #expect(WarmStartHistory.load(for: path) == [])
        }
    }
}

}

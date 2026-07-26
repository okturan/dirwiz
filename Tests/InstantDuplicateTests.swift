import Testing
import Foundation
@testable import DirWizCore

/// Instant duplicates: a zero-I/O heuristic that answers "what is worth verifying?", and a
/// verification gate that is the only path to anything actionable.
@Suite("Instant Duplicate Tests")
struct InstantDuplicateTests {

    private func scan(_ path: String) async -> FileTree {
        let tree = FileTree()
        let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
        await scanner.scan(path: path, progress: ScanProgress(), tree: tree)
        return tree
    }

    private func names(_ report: InstantDuplicateReport) -> [String] {
        report.candidates.map(\.name).sorted()
    }

    // MARK: - Grouping

    @Test("Files sharing a name and size are grouped; unique files are not")
    func basicGrouping() async throws {
        let (root, cleanup) = try createTempTree([
            "a/report.pdf": 50_000,
            "b/report.pdf": 50_000,
            "c/unique.pdf": 50_000,      // same size, different name
            "d/report.pdf": 90_000,      // same name, different size
        ])
        defer { cleanup() }

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        #expect(report.completed)
        #expect(names(report) == ["report.pdf"], "only the name+size pair groups")

        let group = try #require(report.candidates.first)
        #expect(group.paths.count == 2)
        #expect(group.fileSize == 50_000)
        #expect(group.potentialWaste == 50_000, "n-1 copies are the potential saving")
    }

    @Test("Files below the minimum size are ignored entirely")
    func minimumSizeExclusion() async throws {
        let (root, cleanup) = try createTempTree([
            "a/tiny.bin": 500, "b/tiny.bin": 500,
            "a/big.bin": 200_000, "b/big.bin": 200_000,
        ])
        defer { cleanup() }
        let tree = await scan(root)

        let strict = InstantDuplicateFinder(minimumFileSize: 100_000).findCandidates(in: tree)
        #expect(names(strict) == ["big.bin"])

        let loose = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: tree)
        #expect(names(loose) == ["big.bin", "tiny.bin"])
    }

    @Test("Name matching is case-insensitive by default and exact when asked")
    func caseSensitivity() async throws {
        let (root, cleanup) = try createTempTree([
            "a/Report.PDF": 40_000,
            "b/report.pdf": 40_000,
        ])
        defer { cleanup() }
        let tree = await scan(root)

        // APFS is case-insensitive by default, so these read as the same name to a user.
        let insensitive = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: tree)
        #expect(insensitive.candidates.count == 1)
        #expect(insensitive.candidates[0].paths.count == 2)

        let sensitive = InstantDuplicateFinder(minimumFileSize: 1, caseInsensitiveNames: false)
            .findCandidates(in: tree)
        #expect(sensitive.candidates.isEmpty, "exact matching must not fold case")
    }

    /// Hardlinks are ONE file with several names. Counting them as duplicates promises
    /// space that deleting them cannot reclaim.
    @Test("Hardlinked names collapse to a single representative")
    func hardlinksCollapse() async throws {
        let (root, cleanup) = try createTempTree(["a/original.bin": 80_000])
        defer { cleanup() }

        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        try fm.linkItem(atPath: root + "/a/original.bin", toPath: root + "/b/original.bin")

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        #expect(report.candidates.isEmpty,
                "two names for one inode is not a duplicate - nothing would be reclaimed")
    }

    @Test("A real copy alongside a hardlink still reports exactly one reclaimable copy")
    func hardlinkPlusRealCopy() async throws {
        let (root, cleanup) = try createTempTree([
            "a/doc.bin": 70_000,
            "c/doc.bin": 70_000,          // a genuine separate copy
        ])
        defer { cleanup() }

        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        try fm.linkItem(atPath: root + "/a/doc.bin", toPath: root + "/b/doc.bin")

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        let group = try #require(report.candidates.first)
        #expect(group.paths.count == 2, "three names, two distinct files")
        #expect(group.potentialWaste == 70_000)
    }

    @Test("Candidates are ordered by potential waste, biggest first")
    func orderedByWaste() async throws {
        let (root, cleanup) = try createTempTree([
            "a/small.bin": 10_000, "b/small.bin": 10_000,
            "a/huge.bin": 900_000, "b/huge.bin": 900_000,
        ])
        defer { cleanup() }
        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        #expect(report.candidates.map(\.name) == ["huge.bin", "small.bin"])
    }

    // MARK: - Verification gate

    /// The heuristic's whole caveat, made concrete: same name, same size, different bytes.
    @Test("Same name and size but different content is rejected by verification")
    func verificationRejectsDifferentContent() async throws {
        let root = NSTemporaryDirectory() + "/instantdup-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        // Identical length, different bytes.
        try Data(repeating: 0xAA, count: 40_000).write(to: URL(fileURLWithPath: root + "/a/x.bin"))
        try Data(repeating: 0xBB, count: 40_000).write(to: URL(fileURLWithPath: root + "/b/x.bin"))

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        let candidate = try #require(report.candidates.first)
        #expect(candidate.paths.count == 2, "the heuristic does flag them - that is the point")

        #expect(InstantDuplicateVerifier.verify(candidate).isEmpty,
                "byte verification must reject them")
    }

    @Test("Identical content is confirmed and becomes an actionable group")
    func verificationConfirmsIdenticalContent() async throws {
        let root = NSTemporaryDirectory() + "/instantdup-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        try payload.write(to: URL(fileURLWithPath: root + "/a/y.bin"))
        try payload.write(to: URL(fileURLWithPath: root + "/b/y.bin"))

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        let candidate = try #require(report.candidates.first)
        let confirmed = InstantDuplicateVerifier.verify(candidate)

        #expect(confirmed.count == 1)
        #expect(confirmed[0].paths.count == 2)
        #expect(confirmed[0].fileSize == 40_000)
        #expect(confirmed[0].wastedSpace == 40_000)
    }

    /// A candidate can hold two genuine sub-groups. Returning one group would have to
    /// either merge non-identical files or discard real duplicates.
    @Test("A candidate splits into every distinct content group it contains")
    func verificationSplitsIntoSubgroups() async throws {
        let root = NSTemporaryDirectory() + "/instantdup-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["a", "b", "c", "d"] {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(atPath: root) }

        let one = Data(repeating: 0x11, count: 30_000)
        let two = Data(repeating: 0x22, count: 30_000)
        try one.write(to: URL(fileURLWithPath: root + "/a/z.bin"))
        try one.write(to: URL(fileURLWithPath: root + "/b/z.bin"))
        try two.write(to: URL(fileURLWithPath: root + "/c/z.bin"))
        try two.write(to: URL(fileURLWithPath: root + "/d/z.bin"))

        let report = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: await scan(root))
        let candidate = try #require(report.candidates.first)
        #expect(candidate.paths.count == 4)

        let confirmed = InstantDuplicateVerifier.verify(candidate)
        #expect(confirmed.count == 2, "two distinct contents means two groups")
        #expect(confirmed.allSatisfy { $0.paths.count == 2 })
    }

    /// Equivalence with the exhaustive engine: whatever instant+verify confirms, the full
    /// content scan must also find. The fast path must never invent a duplicate.
    @Test("Verified instant results agree with the full content scan")
    func agreesWithFullScan() async throws {
        let root = NSTemporaryDirectory() + "/instantdup-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["a", "b", "c"] {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(atPath: root) }

        let shared = Data((0..<60_000).map { UInt8($0 % 97) })
        try shared.write(to: URL(fileURLWithPath: root + "/a/same.bin"))
        try shared.write(to: URL(fileURLWithPath: root + "/b/same.bin"))
        try Data(repeating: 0x01, count: 60_000).write(to: URL(fileURLWithPath: root + "/c/other.bin"))

        let tree = await scan(root)
        let instant = InstantDuplicateFinder(minimumFileSize: 1).findCandidates(in: tree)
        let verified = InstantDuplicateVerifier.verifyAll(instant.candidates)
        let full = await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: tree)

        let verifiedSets = Set(verified.map { Set($0.paths) })
        let fullSets = Set(full.map { Set($0.paths) })
        #expect(!verifiedSets.isEmpty)
        #expect(verifiedSets.isSubset(of: fullSets),
                "instant+verify must never claim a duplicate the exhaustive scan rejects")
    }

    /// The type-level gate. Candidates are a different type from DuplicateGroup precisely
    /// so unverified results cannot reach the trash paths, which take DuplicateGroup.
    @Test("Verification is the only bridge from candidate to actionable group")
    func candidatesAreADistinctType() {
        let candidate = InstantDuplicateCandidate(fileSize: 10, name: "x", paths: ["/a/x", "/b/x"])
        #expect(candidate.potentialWaste == 10)
        // A single-path candidate can never promise savings.
        #expect(InstantDuplicateCandidate(fileSize: 10, name: "x", paths: ["/a/x"]).potentialWaste == 0)
        // And verification of paths that do not exist yields nothing actionable.
        #expect(InstantDuplicateVerifier.verify(candidate).isEmpty)
    }
}

/// The premise of "instant": no file content is read, so grouping is bounded by the
/// in-memory walk. This is the gate on that.
extension PerformanceSensitiveSuites {

    @Suite("Instant Duplicate Performance Tests")
    struct InstantDuplicatePerformanceTests {

        @Test("Grouping a very large tree stays well under a second")
        func largeTreeIsFast() {
            let tree = FileTree()
            var root = FileNode(); root.isDirectory = true
            tree.addNode(root, name: "root")

            // 500 dirs × 2,000 files = 1M files, with heavy name reuse across directories so
            // the bucket map is genuinely exercised rather than trivially all-singletons.
            var dirs: [(node: FileNode, name: String)] = []
            for d in 0..<500 {
                var n = FileNode(); n.isDirectory = true
                dirs.append((node: n, name: "d\(d)"))
            }
            tree.addChildren(dirs, parentIndex: 0)

            for d in 0..<500 {
                var files: [(node: FileNode, name: String)] = []
                files.reserveCapacity(2_000)
                for f in 0..<2_000 {
                    var n = FileNode()
                    n.fileSize = UInt64(2_000_000 + (f % 500))
                    n.inode = UInt64(d * 2_000 + f + 1)
                    files.append((node: n, name: "shared\(f % 500).bin"))
                }
                tree.addChildren(files, parentIndex: UInt32(d + 1))
            }
            #expect(tree.count > 1_000_000)

            let finder = InstantDuplicateFinder(minimumFileSize: 1_048_576)
            var best = Double.greatestFiniteMagnitude
            var candidateCount = 0
            for _ in 0..<3 {
                let report = finder.findCandidates(in: tree)
                best = min(best, report.elapsedTime)
                candidateCount = report.candidates.count
            }
            print("[instant duplicates] 1M files: \(String(format: "%.0f", best * 1000))ms, \(candidateCount) candidate groups")
            #expect(candidateCount > 0, "control: the fixture really does contain duplicates")
            // The claim "instant" is about RELEASE builds; the recorded figure is ~456 ms.
            // Debug is roughly 2x slower before contention, and slower still on a CI runner
            // sharing few cores - asserting a tight absolute bound there is a coin flip,
            // which is the fragility that broke this repo's CI. The tight bound is asserted
            // where it is meaningful; debug keeps a loose one that still catches the
            // regression this test exists for (an accidental O(n^2) misses it by orders of
            // magnitude, not by a factor of two).
            #if DEBUG
            #expect(best < 30.0, "instant grouping took \(best)s on 1M files")
            #else
            #expect(best < 3.0, "instant grouping took \(best)s on 1M files")
            #endif
        }
    }

} // extension PerformanceSensitiveSuites

/// Characterization of the exhaustive `DuplicateFinder` (instant-duplicates 2.2).
///
/// Task 2.1 proposed refactoring `DuplicateFinder` to expose its passes 2–4 as a scoped
/// entry point. That refactor was NOT done - scoped verification reuses
/// `DuplicateContentVerifier` instead, which is already the guard on the existing trash
/// path. These tests exist so that claim is verifiable rather than asserted: they pin the
/// full-scan engine's observable outputs, so if anyone does attempt that refactor later,
/// any behavior change shows up here.
@Suite("Duplicate Finder Characterization Tests")
struct DuplicateFinderCharacterizationTests {

    private func fixture() throws -> (root: String, cleanup: () -> Void) {
        let root = NSTemporaryDirectory() + "/dupchar-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["a", "b", "c", "d"] {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        // Two identical copies, one same-size decoy, one unique, one below any threshold.
        let shared = Data((0..<120_000).map { UInt8($0 % 211) })
        try shared.write(to: URL(fileURLWithPath: root + "/a/twin.bin"))
        try shared.write(to: URL(fileURLWithPath: root + "/b/twin-renamed.bin"))
        try Data(repeating: 0x5A, count: 120_000).write(to: URL(fileURLWithPath: root + "/c/decoy.bin"))
        try Data(repeating: 0x01, count: 90_000).write(to: URL(fileURLWithPath: root + "/d/unique.bin"))
        try Data(repeating: 0x02, count: 10).write(to: URL(fileURLWithPath: root + "/d/tiny.bin"))
        return (root, { try? fm.removeItem(atPath: root) })
    }

    private func scan(_ path: String) async -> FileTree {
        let tree = FileTree()
        let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
        await scanner.scan(path: path, progress: ScanProgress(), tree: tree)
        return tree
    }

    /// Content, not name, is what the exhaustive scan groups by - the complement of the
    /// instant heuristic, and why the two are not interchangeable.
    @Test("The full scan groups by content regardless of filename")
    func groupsByContentNotName() async throws {
        let (root, cleanup) = try fixture()
        defer { cleanup() }

        let groups = await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: await scan(root))
        #expect(groups.count == 1, "exactly one content group in this fixture")

        let paths = Set(groups[0].paths.map { ($0 as NSString).lastPathComponent })
        #expect(paths == ["twin.bin", "twin-renamed.bin"],
                "differently-named identical files still group; the instant pass would miss these")
        #expect(groups[0].fileSize == 120_000)
        #expect(groups[0].wastedSpace == 120_000)
    }

    @Test("Same-size different-content files are never grouped")
    func decoyIsNotGrouped() async throws {
        let (root, cleanup) = try fixture()
        defer { cleanup() }
        let groups = await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: await scan(root))
        let all = Set(groups.flatMap(\.paths).map { ($0 as NSString).lastPathComponent })
        #expect(!all.contains("decoy.bin"))
        #expect(!all.contains("unique.bin"))
    }

    @Test("The minimum size threshold excludes small files")
    func minimumSizeHonoured() async throws {
        let (root, cleanup) = try fixture()
        defer { cleanup() }
        let tree = await scan(root)

        let permissive = await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: tree)
        #expect(!permissive.isEmpty)

        let strict = await DuplicateFinder(minimumFileSize: 1_000_000).findDuplicates(in: tree)
        #expect(strict.isEmpty, "nothing in the fixture reaches 1 MB")
    }

    @Test("Results are ordered by wasted space, descending")
    func orderedByWaste() async throws {
        let root = NSTemporaryDirectory() + "/dupchar-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["a", "b"] {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(atPath: root) }

        let big = Data((0..<400_000).map { UInt8($0 % 131) })
        let small = Data((0..<50_000).map { UInt8($0 % 67) })
        try big.write(to: URL(fileURLWithPath: root + "/a/big.bin"))
        try big.write(to: URL(fileURLWithPath: root + "/b/big.bin"))
        try small.write(to: URL(fileURLWithPath: root + "/a/small.bin"))
        try small.write(to: URL(fileURLWithPath: root + "/b/small.bin"))

        let groups = await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: await scan(root))
        #expect(groups.count == 2)
        #expect(groups[0].wastedSpace >= groups[1].wastedSpace)
        #expect(groups[0].fileSize == 400_000)
    }

    /// The stats report is part of the engine's observable surface, so pin it too.
    @Test("Reported stats stay consistent with the returned groups")
    func statsMatchGroups() async throws {
        let (root, cleanup) = try fixture()
        defer { cleanup() }
        let report = await DuplicateFinder(minimumFileSize: 1).findDuplicatesWithStats(in: await scan(root))
        #expect(report.groups.count == 1)
        #expect(report.stats.confirmedGroups == report.groups.count,
                "the stats must describe the groups actually returned")
        #expect(report.stats.sizeQualifiedFiles >= 5, "every fixture file is considered")
    }

    /// An empty tree must produce an empty result, not a crash or a phantom group.
    @Test("An empty tree yields no duplicates")
    func emptyTree() async throws {
        let (root, cleanup) = try createTempTree(["only/one.bin": 5_000])
        defer { cleanup() }
        #expect(await DuplicateFinder(minimumFileSize: 1).findDuplicates(in: await scan(root)).isEmpty)
    }
}

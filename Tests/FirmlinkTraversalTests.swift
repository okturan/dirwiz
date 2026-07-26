import Testing
import Foundation
@testable import DirWizCore

/// End-to-end coverage for firmlink deduplication in `FileScanner`.
///
/// Real firmlinks cannot be reproduced in a fixture - APFS has no directory hard links, and
/// `FileManager.linkItem` on a directory recursively hardlinks the *files* inside it, which
/// is a different (and deliberately out-of-scope) phenomenon. So these tests inject the
/// duplicate-path set through `FileScanner`'s test seam and assert on traversal behavior:
/// the paths the skip set names are not descended into, and nothing else changes.
/// `FirmlinkTableTests` covers the parsing that decides what lands in that set.
@Suite("Firmlink Traversal Tests")
struct FirmlinkTraversalTests {

    private func scan(_ path: String, skipping: Set<String> = []) async -> FileTree {
        let tree = FileTree()
        let scanner = skipping.isEmpty
            ? FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
            : FileScanner(computeBundleSizes: false, deferTreeMaterialization: false,
                          firmlinkDuplicates: skipping)
        await scanner.scan(path: path, progress: ScanProgress(), tree: tree)
        return tree
    }

    private func paths(_ tree: FileTree) -> [String] {
        let snap = tree.pathBuildingSnapshot()
        return snap.nodes.indices.map {
            FileTree.pathFromSnapshot(at: UInt32($0), nodes: snap.nodes,
                                      stringPool: snap.stringPool, rootPath: snap.rootPath)
        }
    }

    private func total(_ tree: FileTree) -> UInt64 { tree.node(at: 0)?.allocatedSize ?? 0 }

    /// The core behavior: a directory named in the duplicate set contributes nothing -
    /// neither its bytes nor its children.
    @Test("A duplicate path is not descended into and contributes no bytes")
    func duplicatePathIsSkipped() async throws {
        let (root, cleanup) = try createTempTree([
            "real/a.bin": 4_000_000,
            "real/nested/b.bin": 2_000_000,
            "dupe/a.bin": 4_000_000,
            "dupe/nested/b.bin": 2_000_000,
        ])
        defer { cleanup() }

        let full = await scan(root)
        let deduped = await scan(root, skipping: [root + "/dupe"])

        let fullPaths = paths(full), dedupedPaths = paths(deduped)
        #expect(fullPaths.contains { $0.hasSuffix("/dupe/a.bin") }, "control: the duplicate exists without dedup")
        #expect(!dedupedPaths.contains { $0.hasSuffix("/dupe/a.bin") }, "skipped subtree must not be enumerated")
        #expect(!dedupedPaths.contains { $0.hasSuffix("/dupe/nested") }, "skipped subtree must not be descended into")

        // the kept side is untouched
        #expect(dedupedPaths.contains { $0.hasSuffix("/real/a.bin") })
        #expect(dedupedPaths.contains { $0.hasSuffix("/real/nested/b.bin") })
        #expect(total(deduped) < total(full), "skipping the duplicate must lower the total")
    }

    /// Deduplication must never be the reason unrelated content disappears.
    @Test("Everything not named in the skip set is still counted")
    func nonDuplicateContentSurvives() async throws {
        let (root, cleanup) = try createTempTree([
            "keep/only-here.bin": 3_000_000,
            "keep/deep/also-here.bin": 1_500_000,
            "dupe/x.bin": 900_000,
        ])
        defer { cleanup() }

        let deduped = await scan(root, skipping: [root + "/dupe"])
        let p = paths(deduped)
        #expect(p.contains { $0.hasSuffix("/keep/only-here.bin") })
        #expect(p.contains { $0.hasSuffix("/keep/deep/also-here.bin") })
        #expect(!p.contains { $0.hasSuffix("/dupe/x.bin") })
    }

    /// The racy half of the original bug: a total-only assertion passes intermittently
    /// against code that attributes content to whichever path wins the race, so pin that
    /// the same path reports the same size every run.
    @Test("Totals and per-path attribution are identical across repeated scans")
    func attributionIsDeterministic() async throws {
        var layout: [String: UInt64] = [:]
        for i in 0..<40 { layout["real/f\(i).bin"] = UInt64(50_000 + i * 1_000) }
        for i in 0..<20 { layout["dupe/f\(i).bin"] = UInt64(50_000 + i * 1_000) }
        for i in 0..<15 { layout["pad\(i)/f.bin"] = 10_000 }
        let (root, cleanup) = try createTempTree(layout)
        defer { cleanup() }

        var totals: [UInt64] = []
        var realSizes: [UInt64] = []
        for _ in 0..<3 {
            let t = await scan(root, skipping: [root + "/dupe"])
            totals.append(total(t))
            let snap = t.pathBuildingSnapshot()
            for i in snap.nodes.indices {
                let p = FileTree.pathFromSnapshot(at: UInt32(i), nodes: snap.nodes,
                                                  stringPool: snap.stringPool, rootPath: snap.rootPath)
                if p.hasSuffix("/real") { realSizes.append(snap.nodes[i].allocatedSize) }
            }
        }
        #expect(Set(totals).count == 1, "root total must be identical across runs, got \(totals)")
        #expect(realSizes.count == 3 && Set(realSizes).count == 1,
            "the kept path must report the same size every run, got \(realSizes)")
    }

    /// Fail-open: with no duplicates supplied, behavior is byte-for-byte the old behavior.
    @Test("An empty skip set reproduces undeduplicated behavior exactly")
    func emptySkipSetIsPreChangeBehavior() async throws {
        let (root, cleanup) = try createTempTree([
            "a/one.bin": 500_000, "b/two.bin": 700_000, "b/deep/three.bin": 300_000,
        ])
        defer { cleanup() }

        let plain = await scan(root)
        let explicitlyEmpty = await scan(root, skipping: [])
        #expect(total(plain) == total(explicitlyEmpty))
        #expect(Set(paths(plain)) == Set(paths(explicitlyEmpty)))
    }

    /// Scope guard: the feature must never engage for a scan rooted at or below the Data
    /// volume, or it would hide content the user explicitly asked to see.
    @Test("Activation scope is limited to scans that span both sides")
    func activationScope() async throws {
        #expect(FirmlinkTable.isActive(forScanRoot: "/"))
        #expect(!FirmlinkTable.isActive(forScanRoot: FirmlinkTable.defaultDataVolumeRoot))
        #expect(!FirmlinkTable.isActive(forScanRoot: FirmlinkTable.defaultDataVolumeRoot + "/Applications"))

        let (root, cleanup) = try createTempTree(["a/one.bin": 500_000])
        defer { cleanup() }
        #expect(!FirmlinkTable.isActive(forScanRoot: root), "an ordinary subtree scan never engages dedup")

        // and a real scanner on that root resolves to an empty set
        let scanner = FileScanner(computeBundleSizes: false, deferTreeMaterialization: false)
        #expect(scanner.resolveFirmlinkDuplicates(forScanRoot: root).isEmpty)
    }
}

import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

// MARK: - Helpers

/// Create a temp directory containing files with specific byte content.
/// Returns the directory URL and a cleanup closure.
private func createTempFiles(
    _ files: [String: Data]
) throws -> (url: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DupFinderTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, data) in files {
        try data.write(to: root.appendingPathComponent(name))
    }
    return (root, { try? FileManager.default.removeItem(at: root) })
}

/// Scan a directory with FileScanner and return a populated FileTree.
private func scanDirectory(_ path: String) async -> FileTree {
    let tree = FileTree()
    let scanner = FileScanner()
    let progress = ScanProgress()
    await scanner.scan(path: path, progress: progress, tree: tree)
    return tree
}

// MARK: - Tests

@Suite("DuplicateFinder Tests")
struct DuplicateFinderTests {

    let finder = DuplicateFinder()

    // MARK: - Zero / one file edge cases

    @Test("Empty tree returns no groups")
    func emptyTree() async {
        let tree = FileTree()
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty)
    }

    @Test("Single file returns no groups")
    func singleFile() async throws {
        let content = Data(repeating: 0xAB, count: 8192)
        let (url, cleanup) = try createTempFiles(["only.bin": content])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty)
    }

    // MARK: - Identical files

    @Test("Two identical files form one group with two paths")
    func twoIdenticalFiles() async throws {
        let content = Data(repeating: 0x42, count: 16_384)
        let (url, cleanup) = try createTempFiles([
            "a.bin": content,
            "b.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 1)
        #expect(groups[0].paths.count == 2)
        #expect(groups[0].fileSize == UInt64(content.count))
        #expect(groups[0].wastedSpace == UInt64(content.count))  // 1 wasted copy
    }

    @Test("Three identical files form one group with three paths")
    func threeIdenticalFiles() async throws {
        let content = Data(repeating: 0x7F, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "x.dat": content,
            "y.dat": content,
            "z.dat": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 1)
        #expect(groups[0].paths.count == 3)
        #expect(groups[0].wastedSpace == UInt64(content.count) * 2)  // 2 wasted copies
    }

    // MARK: - Non-duplicates

    @Test("Two files with different content are not duplicates")
    func differentContent() async throws {
        let a = Data(repeating: 0x01, count: 8192)
        let b = Data(repeating: 0x02, count: 8192)  // same size, different bytes
        let (url, cleanup) = try createTempFiles(["a.bin": a, "b.bin": b])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty, "Same size but different content should not be duplicates")
    }

    @Test("Byte verifier groups only exact matches")
    func byteVerifierGroupsOnlyExactMatches() async throws {
        let a = Data(repeating: 0x01, count: 8192)
        let b = a
        let c = Data(repeating: 0x02, count: 8192)
        let (url, cleanup) = try createTempFiles([
            "a.bin": a,
            "b.bin": b,
            "c.bin": c,
        ])
        defer { cleanup() }

        let groups = DuplicateContentVerifier.exactGroups(
            paths: [
                url.appendingPathComponent("a.bin").path,
                url.appendingPathComponent("b.bin").path,
                url.appendingPathComponent("c.bin").path,
            ],
            expectedSize: UInt64(a.count)
        )

        #expect(groups.count == 1)
        #expect(Set(groups[0].map { URL(fileURLWithPath: $0).lastPathComponent }) == ["a.bin", "b.bin"])
    }

    @Test("Trash safety requires an unselected byte-identical copy")
    func trashSafetyRequiresUnselectedExactCopy() async throws {
        let content = Data(repeating: 0xAB, count: 8192)
        let (url, cleanup) = try createTempFiles([
            "keep.bin": content,
            "remove.bin": content,
        ])
        defer { cleanup() }

        let keepPath = url.appendingPathComponent("keep.bin").path
        let removePath = url.appendingPathComponent("remove.bin").path
        let group = DuplicateGroup(fileSize: UInt64(content.count), hash: 1, paths: [keepPath, removePath])

        let safety = DuplicateContentVerifier.trashSafety(for: group, selectedPaths: [removePath])

        #expect(safety.safePaths == [removePath])
        #expect(safety.unsafePaths.isEmpty)
    }

    @Test("Trash safety rejects files whose unselected copy changed after scan")
    func trashSafetyRejectsChangedUnselectedCopy() async throws {
        let content = Data(repeating: 0xAB, count: 8192)
        var changed = content
        changed[1024] = 0xCD
        let (url, cleanup) = try createTempFiles([
            "keep.bin": content,
            "remove.bin": content,
        ])
        defer { cleanup() }

        let keepURL = url.appendingPathComponent("keep.bin")
        let removePath = url.appendingPathComponent("remove.bin").path
        let group = DuplicateGroup(
            fileSize: UInt64(content.count),
            hash: 1,
            paths: [keepURL.path, removePath]
        )

        try changed.write(to: keepURL, options: .atomic)

        let safety = DuplicateContentVerifier.trashSafety(for: group, selectedPaths: [removePath])

        #expect(safety.safePaths.isEmpty)
        #expect(safety.unsafePaths == [removePath])
    }

    @Test("Two files with different sizes are not duplicates")
    func differentSizes() async throws {
        let a = Data(repeating: 0xFF, count: 4096)
        let b = Data(repeating: 0xFF, count: 8192)  // different size
        let (url, cleanup) = try createTempFiles(["small.bin": a, "large.bin": b])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty)
    }

    // MARK: - Multiple groups

    @Test("Two independent duplicate pairs produce two groups")
    func twoIndependentPairs() async throws {
        let red = Data(repeating: 0xAA, count: 1024)
        let blue = Data(repeating: 0xBB, count: 2048)
        let (url, cleanup) = try createTempFiles([
            "red1.bin": red,
            "red2.bin": red,
            "blue1.bin": blue,
            "blue2.bin": blue,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 2)
        // Groups sorted by wasted space descending.
        #expect(groups[0].wastedSpace >= groups[1].wastedSpace)
    }

    @Test("Mix of duplicates and unique files reports only duplicates")
    func mixedContent() async throws {
        let dup = Data(repeating: 0xCC, count: 4096)
        let unique1 = Data(repeating: 0x11, count: 4096)  // same size as dup, different bytes
        let unique2 = Data(repeating: 0x22, count: 8192)  // different size entirely
        let (url, cleanup) = try createTempFiles([
            "dup_a.bin": dup,
            "dup_b.bin": dup,
            "unique1.bin": unique1,
            "unique2.bin": unique2,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 1, "Only the dup pair should form a group")
        #expect(groups[0].paths.count == 2)
    }

    // MARK: - Large file hash correctness

    @Test("Files larger than 8KB use partial hash + full hash passes")
    func largeFileDuplication() async throws {
        // Files > 8KB exercise the partial-hash head+tail read and full-file hash.
        let content = Data(repeating: 0x55, count: 256 * 1024)  // 256KB
        let (url, cleanup) = try createTempFiles([
            "large_a.bin": content,
            "large_b.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 1)
        #expect(groups[0].fileSize == UInt64(content.count))
    }

    @Test("Large files that differ only in middle bytes are not duplicates")
    func largeFilesNearDuplicate() async throws {
        // Same head (4KB) and tail (4KB) — only middle byte differs.
        // The partial hash (head+tail) would call these duplicates,
        // but the full-file hash must correctly distinguish them.
        let a = Data(repeating: 0xAA, count: 65_536)
        var b = Data(repeating: 0xAA, count: 65_536)
        b[32_768] = 0xBB
        let (url, cleanup) = try createTempFiles([
            "a.bin": a,
            "b.bin": b,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty,
            "Files with same head+tail but different middle should not be duplicates")
    }

    @Test("Small duplicate files are confirmed without a second full-hash pass")
    func smallDuplicatesSkipFullHashPass() async throws {
        let content = Data(repeating: 0x5A, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "a.bin": content,
            "b.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let report = await finder.findDuplicatesWithStats(in: tree)

        #expect(report.groups.count == 1)
        #expect(report.stats.totalCandidates == 2)
        #expect(report.stats.totalFullCandidates == 0,
            "Small files already fully read during the partial pass should not be reread")
        #expect(report.stats.fullHashedFiles == 0)
    }

    // MARK: - Progress callback

    @Test("Progress callback is invoked during scan")
    @MainActor
    func progressCallback() async throws {
        let content = Data(repeating: 0x99, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "p1.bin": content,
            "p2.bin": content,
            "p3.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let localFinder = DuplicateFinder()

        var callbackFired = false
        var lastTotal = 0
        var sawGroupingPhase = false
        var sawHashingPhase = false
        var sawHashingPhaseStart = false
        let groups = await localFinder.findDuplicates(in: tree) { update in
            callbackFired = true
            lastTotal = update.total
            if update.phase == .groupingBySize { sawGroupingPhase = true }
            if update.phase == .partialHashing || update.phase == .fullHashing { sawHashingPhase = true }
            if (update.phase == .partialHashing || update.phase == .fullHashing) && update.processed == 0 {
                sawHashingPhaseStart = true
            }
        }

        #expect(callbackFired, "Progress callback should have been called")
        #expect(lastTotal > 0, "Total candidates should be reported")
        #expect(sawGroupingPhase, "Grouping phase should be reported before hashing starts")
        #expect(sawHashingPhase, "A hashing phase should be reported for duplicate candidates")
        #expect(sawHashingPhaseStart, "Hashing should emit an initial 0/N update before work completes")
        #expect(!groups.isEmpty, "Should have found duplicates")
    }

    // MARK: - Sorted output

    @Test("Groups are sorted by wasted space descending")
    func groupsSortedByWastedSpace() async throws {
        let small = Data(repeating: 0x11, count: 1024)   // 1KB, wastes 1KB
        let large = Data(repeating: 0x22, count: 10_240) // 10KB, wastes 10KB
        let (url, cleanup) = try createTempFiles([
            "small1.bin": small,
            "small2.bin": small,
            "large1.bin": large,
            "large2.bin": large,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.count == 2)
        #expect(groups[0].wastedSpace > groups[1].wastedSpace,
            "Largest wasted space should come first")
        #expect(groups[0].fileSize == UInt64(large.count))
    }

    // MARK: - Zero-byte exclusion

    @Test("Zero-byte files are excluded from duplicate groups")
    func zeroBytesExcluded() async throws {
        let (url, cleanup) = try createTempFiles([
            "empty1.txt": Data(),
            "empty2.txt": Data(),
            "empty3.txt": Data(),
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)
        #expect(groups.isEmpty, "Zero-byte files should not form duplicate groups")
    }

    @Test("Large same-size groups with different middles are filtered before full hashing")
    func largeGroupMiddleSamplingAvoidsFullHashExplosion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DupFinderLargeGroup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let base = Data(repeating: 0xAA, count: 65_536)
        for i in 0..<70 {
            var data = base
            data[32_768] = UInt8(i)
            try data.write(to: root.appendingPathComponent("file-\(i).bin"))
        }

        let tree = await scanDirectory(root.path)
        let report = await finder.findDuplicatesWithStats(in: tree)

        #expect(report.groups.isEmpty, "No files share the same full contents")
        #expect(report.stats.totalCandidates == 70, "All files should enter the same size bucket")
        #expect(report.stats.totalFullCandidates == 0,
            "Large-group middle sampling should eliminate these before full hashing")
    }

    @Test("Minimum file size affects duplicate candidate counts")
    func minimumFileSizeChangesCandidateTotals() async throws {
        let small = Data(repeating: 0x11, count: 4 * 1024)
        let medium = Data(repeating: 0x22, count: 2 * 1024 * 1024)
        let large = Data(repeating: 0x33, count: 20 * 1024 * 1024)
        let (url, cleanup) = try createTempFiles([
            "small-a.bin": small,
            "small-b.bin": small,
            "medium-a.bin": medium,
            "medium-b.bin": medium,
            "large-a.bin": large,
            "large-b.bin": large,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)

        let oneKBReport = await DuplicateFinder(minimumFileSize: 1_024).findDuplicatesWithStats(in: tree)
        let tenMBReport = await DuplicateFinder(minimumFileSize: 10 * 1_048_576).findDuplicatesWithStats(in: tree)

        #expect(oneKBReport.stats.totalCandidates == 6)
        #expect(tenMBReport.stats.totalCandidates == 2,
            "Only the 20 MB pair should remain once the threshold is raised to 10 MB")
        #expect(tenMBReport.groups.count == 1)
    }

    // MARK: - Cancellation

    @Test("Pre-cancelled task returns empty results")
    func preCancelledDuplicateScan() async throws {
        let content = Data(repeating: 0x42, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "a.bin": content,
            "b.bin": content,
            "c.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)

        // cancelAll() before addTask ensures the child task starts pre-cancelled,
        // so Task.isCancelled is true from the first iteration of pass 1.
        let groups = await withTaskGroup(of: [DuplicateGroup].self) { group in
            group.cancelAll()
            group.addTask {
                await DuplicateFinder().findDuplicates(in: tree)
            }
            return await group.reduce(into: [DuplicateGroup]()) { $0 = $1 }
        }

        #expect(groups.isEmpty, "Scan in a cancelled task should return empty results")
    }

    // MARK: - Hardlink exclusion

    @Test("Hardlinked files sharing an inode are excluded from duplicate groups")
    func hardlinksExcluded() async throws {
        // Create two files with identical content, then hardlink one to a third path.
        // The hardlink (same inode as original) should be collapsed, leaving only
        // the two distinct-inode files as a valid duplicate pair.
        let content = Data(repeating: 0xDE, count: 8192)
        let (url, cleanup) = try createTempFiles([
            "original.bin": content,
            "copy.bin": content,
        ])
        defer { cleanup() }

        // Create a hardlink to original.bin
        let originalPath = url.appendingPathComponent("original.bin").path
        let linkPath = url.appendingPathComponent("link_to_original.bin").path
        let rc = Darwin.link(originalPath, linkPath)
        #expect(rc == 0, "link() should succeed, got errno \(errno)")

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)

        // There should still be one group (original + copy), but the hardlink
        // should be collapsed with original, so exactly 2 paths, not 3.
        #expect(groups.count == 1, "Should have one duplicate group")
        #expect(groups[0].paths.count == 2,
            "Hardlink should be collapsed: 2 unique inodes, not 3 paths")
        #expect(groups[0].wastedSpace == UInt64(content.count),
            "Wasted space should reflect 1 extra copy, not 2")
    }

    @Test("Duplicate finalization falls back when node identity metadata is missing")
    func duplicateFallbackWithoutNodeMetadata() async throws {
        let content = Data(repeating: 0xDE, count: 8192)
        let (url, cleanup) = try createTempFiles([
            "original.bin": content,
            "copy.bin": content,
        ])
        defer { cleanup() }

        let originalPath = url.appendingPathComponent("original.bin").path
        let linkPath = url.appendingPathComponent("link_to_original.bin").path
        let rc = Darwin.link(originalPath, linkPath)
        #expect(rc == 0, "link() should succeed, got errno \(errno)")

        let tree = FileTree()
        tree.setRootPath(url.path)

        var root = FileNode()
        root.isDirectory = true
        _ = tree.addNode(root, name: url.lastPathComponent)

        var original = FileNode()
        original.fileSize = UInt64(content.count)
        var copy = FileNode()
        copy.fileSize = UInt64(content.count)
        var link = FileNode()
        link.fileSize = UInt64(content.count)
        _ = tree.addChildren([
            (node: original, name: "original.bin"),
            (node: copy, name: "copy.bin"),
            (node: link, name: "link_to_original.bin"),
        ], parentIndex: 0)

        let groups = await finder.findDuplicates(in: tree)

        #expect(groups.count == 1)
        #expect(groups[0].paths.count == 2,
            "Fallback lstat path should still collapse hardlinks when node metadata is missing")
    }

    @Test("All-hardlink group is removed entirely")
    func allHardlinksNoGroup() async throws {
        // Two files that are hardlinks of each other — same inode, so no real duplication.
        let content = Data(repeating: 0xAF, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "file.bin": content,
        ])
        defer { cleanup() }

        // Hardlink file.bin to another name — both point to the same inode.
        let filePath = url.appendingPathComponent("file.bin").path
        let linkPath = url.appendingPathComponent("hardlink.bin").path
        let rc = Darwin.link(filePath, linkPath)
        #expect(rc == 0, "link() should succeed")

        let tree = await scanDirectory(url.path)
        let groups = await finder.findDuplicates(in: tree)

        // Both paths share the same inode, so after dedup the group has only 1 unique
        // inode and should be dropped entirely.
        #expect(groups.isEmpty,
            "Hardlinks to the same inode should not form a duplicate group")
    }
}

import Testing
import Foundation
@testable import DirWizLib

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

    // MARK: - Progress callback

    @Test("Progress callback is invoked during scan")
    func progressCallback() async throws {
        let content = Data(repeating: 0x99, count: 4096)
        let (url, cleanup) = try createTempFiles([
            "p1.bin": content,
            "p2.bin": content,
            "p3.bin": content,
        ])
        defer { cleanup() }

        let tree = await scanDirectory(url.path)

        var callbackFired = false
        var lastTotal = 0
        let groups = await finder.findDuplicates(in: tree) { processed, total in
            callbackFired = true
            lastTotal = total
            _ = processed // avoid unused warning
        }

        #expect(callbackFired, "Progress callback should have been called")
        #expect(lastTotal > 0, "Total candidates should be reported")
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
}

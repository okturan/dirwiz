import Testing
import Foundation
@testable import DirWizLib

@Suite("HardlinkFinder Tests")
struct HardlinkFinderTests {

    // MARK: - Helpers

    /// Create a temp directory with some regular files and hardlinks between them.
    /// Returns (rootPath, cleanup).
    private func createHardlinkTree() throws -> (path: String, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizHardlinkTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create original files.
        let file1 = tempDir.appendingPathComponent("original.txt")
        let data1 = Data(repeating: 0xAB, count: 1024)
        try data1.write(to: file1)

        let file2 = tempDir.appendingPathComponent("unique.txt")
        let data2 = Data(repeating: 0xCD, count: 512)
        try data2.write(to: file2)

        // Create a subdirectory with a hardlink to file1.
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let link1 = subDir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: file1, to: link1)

        // Create another hardlink to file1 in sub.
        let link2 = subDir.appendingPathComponent("another_link.txt")
        try FileManager.default.linkItem(at: file1, to: link2)

        return (tempDir.path, { try? FileManager.default.removeItem(at: tempDir) })
    }

    // MARK: - Tests

    @Test("HardlinkGroup wastedSpace calculation")
    func wastedSpaceCalculation() {
        let group = HardlinkGroup(inode: 42, device: 1, fileSize: 1000, paths: ["/a", "/b", "/c"])
        // 3 links, 1 "extra" = 2 * fileSize
        #expect(group.wastedSpace == 2000)
    }

    @Test("HardlinkGroup with single path has zero wasted space")
    func singlePathZeroWastedSpace() {
        let group = HardlinkGroup(inode: 1, device: 1, fileSize: 500, paths: ["/only"])
        #expect(group.wastedSpace == 0)
    }

    @Test("HardlinkGroup two paths")
    func twoPathsWastedSpace() {
        let group = HardlinkGroup(inode: 7, device: 2, fileSize: 4096, paths: ["/a", "/b"])
        #expect(group.wastedSpace == 4096)
    }

    @Test("findHardlinks detects groups with shared inodes")
    func findHardlinksDetectsGroups() async throws {
        let (rootPath, cleanup) = try createHardlinkTree()
        defer { cleanup() }

        // Scan the tree.
        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: rootPath, progress: progress, tree: tree)

        // Run the hardlink finder.
        let finder = HardlinkFinder()
        let groups = await finder.findHardlinks(in: tree)

        // We created: original.txt with 2 extra hardlinks -> 3 total links to same inode.
        // unique.txt has only 1 link, so it should NOT appear.
        #expect(groups.count == 1, "Expected exactly 1 hardlink group (original.txt + 2 links)")

        let group = try #require(groups.first)
        #expect(group.paths.count == 3, "Expected 3 paths sharing the same inode")
        #expect(group.fileSize == 1024, "Expected fileSize == 1024 bytes")
        #expect(group.wastedSpace == 2048, "Expected wastedSpace == 2 * 1024")
    }

    @Test("findHardlinks returns empty for tree with no hardlinks")
    func findHardlinksEmptyForNoHardlinks() async throws {
        // Create a simple tree with no hardlinks.
        let (rootPath, cleanup) = try createTempTree([
            "a.txt": 100,
            "b.txt": 200,
            "sub/c.txt": 300,
        ])
        defer { cleanup() }

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: rootPath, progress: progress, tree: tree)

        let finder = HardlinkFinder()
        let groups = await finder.findHardlinks(in: tree)

        #expect(groups.isEmpty, "Expected no hardlink groups when no hardlinks exist")
    }

    @Test("findHardlinks on empty tree returns empty")
    func findHardlinksEmptyTree() async {
        let tree = FileTree()
        let finder = HardlinkFinder()
        let groups = await finder.findHardlinks(in: tree)
        #expect(groups.isEmpty)
    }

    @Test("findHardlinks results are sorted by wastedSpace descending")
    func findHardlinksSortedByWastedSpace() async throws {
        // Create two sets of hardlinks: a large file with 2 links and a small file with 3 links.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirWizSortTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Large file: 8192 bytes, 2 hardlinks -> wastedSpace = 8192.
        let large = tempDir.appendingPathComponent("large.bin")
        try Data(repeating: 0xFF, count: 8192).write(to: large)
        let largeLink = tempDir.appendingPathComponent("large_link.bin")
        try FileManager.default.linkItem(at: large, to: largeLink)

        // Small file: 64 bytes, 3 hardlinks -> wastedSpace = 128.
        let small = tempDir.appendingPathComponent("small.bin")
        try Data(repeating: 0x11, count: 64).write(to: small)
        let smallLink1 = tempDir.appendingPathComponent("small_link1.bin")
        let smallLink2 = tempDir.appendingPathComponent("small_link2.bin")
        try FileManager.default.linkItem(at: small, to: smallLink1)
        try FileManager.default.linkItem(at: small, to: smallLink2)

        let tree = FileTree()
        let scanner = FileScanner()
        let progress = ScanProgress()
        await scanner.scan(path: tempDir.path, progress: progress, tree: tree)

        let finder = HardlinkFinder()
        let groups = await finder.findHardlinks(in: tree)

        #expect(groups.count == 2)
        if groups.count == 2 {
            // First group should have the largest wasted space.
            #expect(groups[0].wastedSpace >= groups[1].wastedSpace,
                    "Groups should be sorted descending by wastedSpace")
            #expect(groups[0].wastedSpace == 8192, "Large file should be first (8192 wasted)")
            #expect(groups[1].wastedSpace == 128, "Small file should be second (128 wasted)")
        }
    }

    @Test("HardlinkGroup has unique id per instance")
    func hardlinkGroupUniqueIds() {
        let g1 = HardlinkGroup(inode: 1, device: 1, fileSize: 100, paths: ["/a", "/b"])
        let g2 = HardlinkGroup(inode: 1, device: 1, fileSize: 100, paths: ["/a", "/b"])
        #expect(g1.id != g2.id, "Each HardlinkGroup should have a unique UUID")
    }
}

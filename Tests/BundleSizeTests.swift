import Testing
import Foundation
@testable import DirWizLib

// NOTE: File sizes use 4096-byte multiples to match APFS block size,
// ensuring logical size == allocated size for deterministic assertions.
// (Smaller files get rounded up to one 4096-byte block by the filesystem.)

@Suite("Bundle Size Computation Tests")
struct BundleSizeTests {

    // MARK: - Helpers

    private func scanTree(at path: String) async -> (tree: FileTree, progress: ScanProgress) {
        let scanner = FileScanner()
        let progress = ScanProgress()
        let tree = FileTree()
        await scanner.scan(path: path, progress: progress, tree: tree)
        return (tree, progress)
    }

    /// Find a child node by name under a given parent index.
    private func findChild(named name: String, under parent: UInt32, in tree: FileTree) -> (index: UInt32, node: FileNode)? {
        let range = tree.children(of: parent)
        for i in range {
            if tree.name(at: UInt32(i)) == name {
                return (UInt32(i), tree.nodesSnapshot()[i])
            }
        }
        return nil
    }

    // MARK: - Tests

    @Test("Simple bundle accumulates file size")
    func simpleBundleSize() async throws {
        let (path, cleanup) = try createTempTree([
            "Test.app/Contents/MacOS/binary": 4096,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        guard let (_, bundle) = findChild(named: "Test.app", under: 0, in: tree) else {
            Issue.record("Test.app node not found")
            return
        }

        #expect(bundle.isDirectory, "Bundle should be a directory")
        #expect(bundle.isBundle, "Bundle should be marked as bundle")
        #expect(bundle.childCount == 0, "Bundle should have no children in tree")
        #expect(bundle.fileSize == 4096, "Bundle should have accumulated file size of 4096, got \(bundle.fileSize)")
    }

    @Test("Bundle with multiple files sums sizes")
    func bundleMultipleFiles() async throws {
        let (path, cleanup) = try createTempTree([
            "Test.app/Contents/MacOS/exec": 8192,
            "Test.app/Contents/Resources/data.bin": 16384,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        guard let (_, bundle) = findChild(named: "Test.app", under: 0, in: tree) else {
            Issue.record("Test.app node not found")
            return
        }

        #expect(bundle.isBundle)
        let expected: UInt64 = 8192 + 16384
        #expect(bundle.fileSize == expected,
            "Bundle should sum all contained files: expected \(expected), got \(bundle.fileSize)")
    }

    @Test("Empty bundle has zero file size")
    func emptyBundle() async throws {
        let (path, cleanup) = try createTempTree([
            "Empty.app/": 0,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        guard let (_, bundle) = findChild(named: "Empty.app", under: 0, in: tree) else {
            Issue.record("Empty.app node not found")
            return
        }

        #expect(bundle.isBundle)
        #expect(bundle.isDirectory)
        #expect(bundle.childCount == 0)
        #expect(bundle.fileSize == 0, "Empty bundle should have zero file size")
    }

    @Test("Bundle with deeply nested directories")
    func deepBundleContents() async throws {
        let (path, cleanup) = try createTempTree([
            "Deep.app/a/b/c/file.txt": 4096,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        guard let (_, bundle) = findChild(named: "Deep.app", under: 0, in: tree) else {
            Issue.record("Deep.app node not found")
            return
        }

        #expect(bundle.isBundle)
        #expect(bundle.childCount == 0, "Bundle should be a leaf in the tree")
        #expect(bundle.fileSize == 4096, "Deep bundle should find nested file: expected 4096, got \(bundle.fileSize)")
    }

    @Test("Bundle is treated as opaque leaf with no tree children")
    func bundleIsLeaf() async throws {
        let (path, cleanup) = try createTempTree([
            "Leaf.app/Contents/MacOS/binary": 8192,
            "Leaf.app/Contents/Resources/icon.png": 4096,
            "Leaf.app/Contents/Info.plist": 4096,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        guard let (_, bundle) = findChild(named: "Leaf.app", under: 0, in: tree) else {
            Issue.record("Leaf.app node not found")
            return
        }

        let expected: UInt64 = 8192 + 4096 + 4096
        #expect(bundle.isBundle, "Should be marked as bundle")
        #expect(bundle.isDirectory, "Bundle is still a directory")
        #expect(bundle.childCount == 0, "Bundle children should NOT appear in tree")
        #expect(bundle.fileSize > 0, "Bundle should have accumulated size")
        #expect(bundle.fileSize == expected,
            "Bundle size should be sum of all files: expected \(expected), got \(bundle.fileSize)")
    }

    @Test("Non-bundle directory is recursed normally alongside bundle")
    func nonBundleDirRecursedNormally() async throws {
        let (path, cleanup) = try createTempTree([
            "MyApp.app/Contents/MacOS/exec": 4096,
            "regular_dir/file.txt": 8192,
            "regular_dir/sub/deep.txt": 4096,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        // Bundle should be a leaf
        guard let (_, bundle) = findChild(named: "MyApp.app", under: 0, in: tree) else {
            Issue.record("MyApp.app node not found")
            return
        }
        #expect(bundle.isBundle)
        #expect(bundle.childCount == 0)

        // Regular dir should have children in the tree
        guard let (regIdx, regDir) = findChild(named: "regular_dir", under: 0, in: tree) else {
            Issue.record("regular_dir node not found")
            return
        }
        #expect(regDir.isDirectory)
        #expect(!regDir.isBundle, "Regular dir should NOT be a bundle")
        #expect(regDir.childCount > 0, "Regular dir should have children in the tree")

        // Verify regular dir children exist
        let fileChild = findChild(named: "file.txt", under: regIdx, in: tree)
        #expect(fileChild != nil, "file.txt should be a child of regular_dir")
        if let (_, fileNode) = fileChild {
            #expect(fileNode.fileSize == 8192)
        }
    }

    @Test("Bundle size propagates to parent accumulation")
    func bundleSizePropagates() async throws {
        let (path, cleanup) = try createTempTree([
            "Container.app/binary": 8192,
            "loose_file.txt": 4096,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        let root = tree.nodesSnapshot()[0]
        let expected: UInt64 = 8192 + 4096
        #expect(root.fileSize == expected,
            "Root should accumulate bundle + loose file: expected \(expected), got \(root.fileSize)")
    }

    @Test("Multiple bundle extensions are recognized")
    func multipleBundleExtensions() async throws {
        let (path, cleanup) = try createTempTree([
            "Test.framework/lib": 4096,
            "Test.xcodeproj/project.pbxproj": 8192,
            "Test.bundle/resource": 12288,
            "Test.plugin/binary": 16384,
        ])
        defer { cleanup() }

        let (tree, _) = await scanTree(at: path)

        let bundleNames = ["Test.framework", "Test.xcodeproj", "Test.bundle", "Test.plugin"]
        for name in bundleNames {
            guard let (_, node) = findChild(named: name, under: 0, in: tree) else {
                Issue.record("\(name) node not found")
                continue
            }
            #expect(node.isBundle, "\(name) should be recognized as a bundle")
            #expect(node.childCount == 0, "\(name) should have no tree children")
            #expect(node.fileSize > 0, "\(name) should have accumulated size")
        }
    }
}

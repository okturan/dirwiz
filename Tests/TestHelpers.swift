import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Build a temporary directory tree for testing. Returns (rootPath, cleanup).
/// Example: createTempTree(["docs/readme.txt": 100, "images/photo.jpg": 500, "empty_dir/": 0])
/// Keys ending with "/" create empty directories. Other keys create files of the given byte size.
func createTempTree(_ layout: [String: UInt64]) throws -> (path: String, cleanup: () -> Void) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirWizTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    for (relativePath, size) in layout {
        let fullURL = tempDir.appendingPathComponent(relativePath)
        if relativePath.hasSuffix("/") {
            try FileManager.default.createDirectory(at: fullURL, withIntermediateDirectories: true)
        } else {
            let parentDir = fullURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let data = Data(count: Int(size))
            try data.write(to: fullURL)
        }
    }

    return (tempDir.path, { try? FileManager.default.removeItem(at: tempDir) })
}

// MARK: - App Support Override

/// All suites that mutate the process-global `DIRWIZ_APP_SUPPORT_DIR` env var — currently
/// `TreeCacheTests`, `WarmStartComposedPipelineTests`, and `TemporalDiffTests` — live nested
/// under this serialized parent. swift-testing parallelizes across top-level suites, and
/// `.serialized` on a suite only serializes ITS OWN children against each other — it does
/// nothing to prevent a *different* top-level `.serialized` suite from interleaving with it.
/// `.serialized` DOES propagate recursively to nested suites, though, so nesting every
/// env-mutating suite under one serialized parent is the only construct that keeps them from
/// racing each other (empirically verified for plan 032 with a throwaway pair of nested probe
/// suites + timestamps: zero overlap between them once nested here).
///
/// Rule for future suites: anything that touches `DIRWIZ_APP_SUPPORT_DIR` — via
/// `withTemporaryAppSupportDir` or inline `setenv` — must be declared as
/// `extension AppSupportEnvSuites { @Suite(...) struct Foo { ... } }`, never as a bare
/// top-level `@Suite`.
@Suite(.serialized) enum AppSupportEnvSuites {}

/// Point DIRWIZ_APP_SUPPORT_DIR at a scratch directory for the duration of a test,
/// restoring the previous value (or unsetting it) afterward. Shared by `TreeCacheTests`,
/// `WarmStartComposedPipelineTests`, and `TemporalDiffTests` — all nested under
/// `AppSupportEnvSuites` above, which is what actually keeps their env mutations from
/// interleaving with each other.
func withTemporaryAppSupportDir<T>(_ body: () async throws -> T) async rethrows -> T {
    let tempSupportRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirWizAppSupport_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempSupportRoot, withIntermediateDirectories: true)
    let previousOverride = ProcessInfo.processInfo.environment["DIRWIZ_APP_SUPPORT_DIR"]
    setenv("DIRWIZ_APP_SUPPORT_DIR", tempSupportRoot.path, 1)
    defer {
        if let previousOverride {
            setenv("DIRWIZ_APP_SUPPORT_DIR", previousOverride, 1)
        } else {
            unsetenv("DIRWIZ_APP_SUPPORT_DIR")
        }
        try? FileManager.default.removeItem(at: tempSupportRoot)
    }
    return try await body()
}

// MARK: - Tree Equivalence

/// Per-node facts compared when asserting two trees are structurally indistinguishable.
struct TreeNodeSummary: Equatable, CustomStringConvertible {
    let isDirectory: Bool
    let isBundle: Bool
    let fileSize: UInt64
    let allocatedSize: UInt64
    let childCount: UInt32

    var description: String {
        "(dir: \(isDirectory), bundle: \(isBundle), size: \(fileSize), alloc: \(allocatedSize), children: \(childCount))"
    }
}

func summarizeTree(_ tree: FileTree) -> [String: TreeNodeSummary] {
    var result: [String: TreeNodeSummary] = [:]
    for i in 0..<tree.count {
        let node = tree.nodes[i]
        result[tree.path(at: UInt32(i))] = TreeNodeSummary(
            isDirectory: node.isDirectory,
            isBundle: node.isBundle,
            fileSize: node.fileSize,
            allocatedSize: node.allocatedSize,
            childCount: node.childCount
        )
    }
    return result
}

/// Asserts `actual` is structurally indistinguishable from `expected`: same path set,
/// per-path fileSize/allocatedSize/isDirectory/childCount, and equal root aggregate
/// totals. `expected` is typically a fresh cold scan of the same on-disk fixture.
/// Shared by `SubtreeRescanTests` (per-splice equivalence) and `WarmStartTests`
/// (composed warm-start pipeline equivalence) rather than duplicated between them.
func assertTreesEquivalent(_ actual: FileTree, _ expected: FileTree, _ context: String) {
    let actualByPath = summarizeTree(actual)
    let expectedByPath = summarizeTree(expected)

    #expect(Set(actualByPath.keys) == Set(expectedByPath.keys),
        "\(context): path sets differ (actual: \(actualByPath.keys.sorted()), expected: \(expectedByPath.keys.sorted()))")

    for (path, expectedValue) in expectedByPath {
        guard let actualValue = actualByPath[path] else {
            Issue.record("\(context): path \(path) missing from the rescanned tree")
            continue
        }
        #expect(actualValue == expectedValue,
            "\(context): mismatch at \(path): rescanned \(actualValue) vs cold \(expectedValue)")
    }

    guard !actual.isEmpty, !expected.isEmpty else {
        Issue.record("\(context): one of the trees is empty")
        return
    }
    let actualRoot = actual.nodes[0]
    let expectedRoot = expected.nodes[0]
    #expect(actualRoot.fileSize == expectedRoot.fileSize,
        "\(context): root fileSize mismatch (rescanned \(actualRoot.fileSize) vs cold \(expectedRoot.fileSize))")
    #expect(actualRoot.allocatedSize == expectedRoot.allocatedSize,
        "\(context): root allocatedSize mismatch (rescanned \(actualRoot.allocatedSize) vs cold \(expectedRoot.allocatedSize))")
}

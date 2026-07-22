import Testing
import Foundation
@testable import DirWizCore

// MARK: - Test Helpers
//
// TreeCache's binary header is reproduced here (offsets, FNV-1a 64) so tests can
// hand-patch a saved cache file and still recompute a valid checksum — the same
// hand-assembled-header discipline used in TemporalDiffTests for TemporalSnapshot.
//
// `withTemporaryAppSupportDir` lives in TestHelpers.swift — shared with WarmStartTests,
// which also needs a scratch TreeCache location.

/// Build a small in-memory tree rooted at a real on-disk path (needed so TreeCache's
/// volume-UUID lookup resolves to a real volume, not an empty string). 3 nodes total:
/// root = 0, a.txt = 1, b.txt = 2.
private func makeSimpleTree(rootPath: String) -> FileTree {
    let tree = FileTree()
    tree.setRootPath(rootPath)

    var root = FileNode()
    root.isDirectory = true
    tree.addNode(root, name: (rootPath as NSString).lastPathComponent)

    var fileA = FileNode()
    fileA.fileSize = 1_000
    fileA.allocatedSize = 4_096
    var fileB = FileNode()
    fileB.fileSize = 2_000
    fileB.allocatedSize = 4_096
    tree.addChildren([(fileA, "a.txt"), (fileB, "b.txt")], parentIndex: 0)
    tree.propagateSizes()
    return tree
}

/// FNV-1a 64 over raw bytes, reproduced from `TreeCache`'s private implementation so
/// tests can recompute a valid checksum after hand-patching a saved cache file.
private func fnv1a64(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return hash
}

/// Overwrite the trailing 8-byte checksum field with a freshly-computed FNV-1a 64 over
/// everything before it. Call after hand-patching some other byte(s) in `data`.
private func recomputeChecksum(_ data: inout Data) {
    let checksumStart = data.startIndex + data.count - 8
    guard checksumStart >= data.startIndex else { return }
    let checksum = fnv1a64(data[data.startIndex..<checksumStart])
    var le = checksum.littleEndian
    withUnsafeBytes(of: &le) { raw in
        data.replaceSubrange(checksumStart..<data.endIndex, with: raw)
    }
}

/// Resolve the same volume UUID string `TreeCache` computes for `path`, so tests can
/// locate/patch that field precisely.
private func currentVolumeUUID(for path: String) -> String {
    guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]),
          let uuid = values.volumeUUIDString else {
        return ""
    }
    return uuid
}

/// Byte offsets of the fixed-position header fields that follow the variable-length
/// rootPath/volumeUUID strings, mirroring TreeCache's write order exactly:
/// magic(4) + formatVersion(4) + nodeStride(4) + savedAt(8) + lastEventId(8) +
/// rootPathLen(2) + rootPath + isCaseSensitive(1) + linkCountsCaptured(1) +
/// volumeUUIDLen(2) + volumeUUID + nodeCount(4) + stringPoolLen(8) + [nodes...].
private func headerFieldOffsets(rootPath: String, volumeUUID: String) -> (nodeCount: Int, stringPoolLen: Int, nodesStart: Int) {
    let beforeNodeCount = 4 + 4 + 4 + 8 + 8 + 2 + rootPath.utf8.count + 1 + 1 + 2 + volumeUUID.utf8.count
    let stringPoolLenOffset = beforeNodeCount + 4
    let nodesStart = stringPoolLenOffset + 8
    return (nodeCount: beforeNodeCount, stringPoolLen: stringPoolLenOffset, nodesStart: nodesStart)
}

/// Flip a single hex character of a UUID string, preserving its byte length exactly —
/// used to craft a "different but valid-length" volume UUID.
private func flippedUUID(_ uuid: String) -> String {
    var chars = Array(uuid)
    guard let idx = chars.firstIndex(where: { $0 != "-" }) else { return uuid }
    chars[idx] = (chars[idx] == "0") ? "1" : "0"
    return String(chars)
}

private func patchUInt32(_ data: inout Data, at offset: Int, to value: UInt32) {
    var le = value.littleEndian
    let start = data.startIndex + offset
    withUnsafeBytes(of: &le) { raw in
        data.replaceSubrange(start..<(start + 4), with: raw)
    }
}

// MARK: - Tests

// Nested under `AppSupportEnvSuites` (TestHelpers.swift): that parent's `.serialized`
// propagates recursively, which is what actually keeps this suite's env mutations from
// interleaving with `WarmStartComposedPipelineTests` / `TemporalDiffTests`.
extension AppSupportEnvSuites {

@Suite("TreeCache Tests")
struct TreeCacheTests {

    // MARK: 1. Round-trip on a real scan

    @Test("Round-trip on a real scan preserves every node and lastEventId, and the loaded tree is searchable")
    func roundTripOnRealScan() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([
                "docs/readme.txt": 100,
                "docs/notes.md": 200,
                "images/photo.jpg": 500,
            ])
            defer { cleanup() }

            let scanner = FileScanner()
            let progress = ScanProgress()
            let tree = FileTree()
            await scanner.scan(path: path, progress: progress, tree: tree)
            #expect(tree.count > 0)

            try TreeCache.save(tree: tree, lastEventId: 12345)

            let payload = TreeCache.load(for: path)
            #expect(payload != nil)
            guard let payload else { return }

            #expect(payload.lastEventId == 12345)
            #expect(payload.tree.linkCountsCaptured,
                "A scanned tree marks link counts captured; the cache must carry that through")
            guard case .success = TreeCache.loadResult(for: path) else {
                Issue.record("expected .success from loadResult on a valid cache")
                return
            }

            let original = tree.pathBuildingSnapshot()
            let loaded = payload.tree.pathBuildingSnapshot()
            #expect(loaded.nodes.count == original.nodes.count)
            #expect(loaded.rootPath == original.rootPath)

            for i in original.nodes.indices {
                let originalPath = FileTree.pathFromSnapshot(
                    at: UInt32(i), nodes: original.nodes, stringPool: original.stringPool, rootPath: original.rootPath
                )
                let loadedPath = FileTree.pathFromSnapshot(
                    at: UInt32(i), nodes: loaded.nodes, stringPool: loaded.stringPool, rootPath: loaded.rootPath
                )
                #expect(loadedPath == originalPath, "Path mismatch at index \(i)")
                #expect(loaded.nodes[i].fileSize == original.nodes[i].fileSize, "fileSize mismatch at index \(i)")
                #expect(loaded.nodes[i].allocatedSize == original.nodes[i].allocatedSize, "allocatedSize mismatch at index \(i)")
                #expect(loaded.nodes[i].isDirectory == original.nodes[i].isDirectory, "isDirectory mismatch at index \(i)")
                #expect(loaded.nodes[i].childCount == original.nodes[i].childCount, "childCount mismatch at index \(i)")
            }

            // Prove the search-index rebuild path: search should work on the loaded tree
            // even though it was never scanned, only installed from disk.
            let searchIndex = payload.tree.searchIndexSnapshot()
            let result = SearchEngine.search(
                query: "readme", nodes: loaded.nodes, searchPool: searchIndex.pool, searchEntries: searchIndex.entries
            )
            #expect(result.totalMatches == 1, "Should find readme.txt in the loaded tree")
        }
    }

    // MARK: 2. Truncated file

    @Test("Truncated cache file fails closed without crashing")
    func truncatedFileFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            #expect(data.count > 100, "Fixture cache should be large enough to chop 100 bytes")
            data.removeLast(100)
            try data.write(to: url)

            // warm-start-observability: a structurally-corrupt cache must be
            // distinguishable from "no cache exists" — not just both collapsing to nil.
            // loadResult() is called FIRST and ONCE: it invalidates (deletes) a
            // structurally-corrupt file as a side effect, so calling load() first would
            // destroy the evidence before loadResult() ever saw it.
            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for a truncated cache")
                return
            }
            #expect(reason == "cache file was incomplete")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 3. Checksum corruption

    @Test("Checksum corruption fails closed")
    func checksumCorruptionFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let uuid = currentVolumeUUID(for: path)
            let offsets = headerFieldOffsets(rootPath: path, volumeUUID: uuid)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            let flipOffset = data.startIndex + offsets.nodesStart + 5 // mid-first-node
            #expect(flipOffset < data.endIndex)
            data[flipOffset] ^= 0xFF
            try data.write(to: url)

            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for a checksum-corrupted cache")
                return
            }
            #expect(reason == "cache file was corrupted")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 4. Version bump

    @Test("Unsupported format version fails closed")
    func versionBumpFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            // formatVersion follows the 4-byte magic. Patch to v1: pre-link-count caches
            // must fail closed (their flag bit 2 has no meaning), which doubles as the
            // generic wrong-version rejection.
            patchUInt32(&data, at: 4, to: 1)
            try data.write(to: url)

            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for a version-mismatched cache")
                return
            }
            #expect(reason == "cache format outdated")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 5. Stride mismatch

    @Test("Node stride mismatch fails closed")
    func strideMismatchFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            // nodeStride follows magic(4) + formatVersion(4).
            patchUInt32(&data, at: 8, to: UInt32(MemoryLayout<FileNode>.stride) + 8)
            try data.write(to: url)

            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for a stride-mismatched cache")
                return
            }
            #expect(reason == "cache format outdated")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 6. Huge declared nodeCount with a small file

    @Test("Huge declared node count with a small file fails closed before allocating")
    func hugeNodeCountIsClampedBeforeAllocating() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let uuid = currentVolumeUUID(for: path)
            let offsets = headerFieldOffsets(rootPath: path, volumeUUID: uuid)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            patchUInt32(&data, at: offsets.nodeCount, to: UInt32.max)
            try data.write(to: url)

            // A declared count this far past what's actually in the file trips the
            // bounds guard before allocating — that guard throws .truncated (the
            // file's on-disk content can't back up what the header claims).
            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for an impossible declared node count")
                return
            }
            #expect(reason == "cache file was incomplete")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 7. Volume UUID mismatch

    @Test("Volume UUID mismatch fails closed (volume was replaced/restored)")
    func volumeUUIDMismatchFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let uuid = currentVolumeUUID(for: path)
            try #require(!uuid.isEmpty, "Fixture path must resolve to a real volume UUID for this test")
            let patchedUUID = flippedUUID(uuid)
            #expect(patchedUUID != uuid)
            #expect(patchedUUID.utf8.count == uuid.utf8.count)

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            let uuidBytesOffset = data.startIndex + 4 + 4 + 4 + 8 + 8 + 2 + path.utf8.count + 1 + 2
            data.replaceSubrange(uuidBytesOffset..<(uuidBytesOffset + uuid.utf8.count), with: Array(patchedUUID.utf8))
            recomputeChecksum(&data)
            try data.write(to: url)

            #expect(TreeCache.load(for: path) == nil)
            // Not structural corruption — per TreeCache's own doc comment this file may
            // still be valid for its actual owner, so it must NOT read as a rejection
            // (that would misleadingly tell the user "your cache was corrupted" when
            // really a different volume happens to be mounted at this path).
            guard case .noCacheFile = TreeCache.loadResult(for: path) else {
                Issue.record("expected .noCacheFile (not .rejected) for a volume-UUID mismatch")
                return
            }
        }
    }

    // MARK: 8. rootPath mismatch

    @Test("Requesting a different root path fails closed, including a same-bytes/mismatched-header patch")
    func rootPathMismatchFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (pathA, cleanupA) = try createTempTree([:])
            defer { cleanupA() }
            let (pathB, cleanupB) = try createTempTree([:])
            defer { cleanupB() }

            let treeA = makeSimpleTree(rootPath: pathA)
            try TreeCache.save(tree: treeA, lastEventId: 1)

            // (a) Distinct cache file — no cache was ever written for pathB.
            #expect(TreeCache.load(for: pathB) == nil)
            guard case .noCacheFile = TreeCache.loadResult(for: pathB) else {
                Issue.record("expected .noCacheFile when nothing was ever saved for this path")
                return
            }

            // (b) Patch test: place A's saved bytes at B's cache location, so the
            // header's own rootPath field ("A") disagrees with the requested root ("B").
            let urlA = TreeCache.cacheURL(for: pathA)
            let urlB = TreeCache.cacheURL(for: pathB)
            let dataA = try Data(contentsOf: urlA)
            try FileManager.default.createDirectory(at: urlB.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dataA.write(to: urlB)

            #expect(TreeCache.load(for: pathB) == nil)
            // Same reasoning as the volume-UUID case: a root-path mismatch means this
            // cache belongs to a different lookup, not that the requested lookup's
            // cache is broken — must read as .noCacheFile, not .rejected.
            guard case .noCacheFile = TreeCache.loadResult(for: pathB) else {
                Issue.record("expected .noCacheFile (not .rejected) for a root-path mismatch")
                return
            }
        }
    }

    // MARK: 9. Out-of-bounds structural corruption

    @Test("Out-of-bounds child range fails the structural sanity pass")
    func outOfBoundsStructureFailsClosed() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)
            let totalNodes = tree.count // 3: root, a.txt, b.txt

            let uuid = currentVolumeUUID(for: path)
            let offsets = headerFieldOffsets(rootPath: path, volumeUUID: uuid)
            guard let firstChildFieldOffset = MemoryLayout<FileNode>.offset(of: \.firstChildIndex) else {
                Issue.record("Could not determine FileNode.firstChildIndex layout offset")
                return
            }

            let url = TreeCache.cacheURL(for: path)
            var data = try Data(contentsOf: url)
            // Root is node 0 — patch its firstChildIndex to point past the end of the tree.
            let patchOffset = offsets.nodesStart + firstChildFieldOffset
            patchUInt32(&data, at: patchOffset, to: UInt32(totalNodes + 10))
            recomputeChecksum(&data)
            try data.write(to: url)

            guard case .rejected(let reason) = TreeCache.loadResult(for: path) else {
                Issue.record("expected .rejected for a structurally-invalid cache")
                return
            }
            #expect(reason == "cache data failed a consistency check")
            #expect(TreeCache.load(for: path) == nil)
        }
    }

    // MARK: 10. invalidate

    @Test("invalidate removes the cache file so a subsequent load returns nil")
    func invalidateRemovesFile() async throws {
        try await withTemporaryAppSupportDir {
            let (path, cleanup) = try createTempTree([:])
            defer { cleanup() }
            let tree = makeSimpleTree(rootPath: path)
            try TreeCache.save(tree: tree, lastEventId: 1)

            let url = TreeCache.cacheURL(for: path)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(TreeCache.load(for: path) != nil)

            TreeCache.invalidate(for: path)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(TreeCache.load(for: path) == nil)
        }
    }
}

} // extension AppSupportEnvSuites

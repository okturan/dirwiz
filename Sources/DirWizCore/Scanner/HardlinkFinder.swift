import Foundation

// MARK: - HardlinkGroup

/// A group of files that all share the same inode (i.e., are hardlinks to the same data).
public struct HardlinkGroup: Identifiable, Sendable {
    public let id: UUID
    public let inode: UInt64
    public let device: UInt32
    public let fileSize: UInt64
    public let paths: [String]

    /// Sum of logical sizes of extra directory entries (paths.count - 1 links beyond the first).
    /// This is NOT reclaimed disk space: hardlinks share blocks, so removing extra links does
    /// not free on-disk data until the last link is removed.
    public var extraLinkBytes: UInt64 {
        fileSize * UInt64(max(0, paths.count - 1))
    }

    public init(inode: UInt64, device: UInt32, fileSize: UInt64, paths: [String]) {
        self.id = UUID()
        self.inode = inode
        self.device = device
        self.fileSize = fileSize
        self.paths = paths
    }
}

// MARK: - HardlinkFinder

/// Detects hardlinked file groups by walking all file nodes in a FileTree,
/// grouping by scan-time (device, inode) identity when available.
///
/// Files sharing the same (device, inode) pair are hardlinks to the same data.
/// Trees produced by the scanner carry per-file link-count flags
/// (`FileTree.linkCountsCaptured`), so grouping only has to touch the few flagged
/// nodes — a pure in-memory pass over a tiny subset. For trees without that
/// guarantee (manually assembled trees in tests), the finder falls back to full
/// per-file grouping, using `lstat` for nodes missing identity metadata.
public struct HardlinkFinder {
    public typealias ProgressHandler = @MainActor @Sendable (_ processed: Int, _ total: Int) -> Void

    public init() {}

    // MARK: - Public API

    /// Find all hardlink groups in the given FileTree.
    ///
    /// - Parameter tree: The scanned file tree to inspect.
    /// - Parameter progress: Optional determinate progress callback for processed files.
    /// - Returns: Array of HardlinkGroup sorted by extraLinkBytes descending,
    ///            containing only groups with 2 or more paths.
    public func findHardlinks(
        in tree: FileTree,
        progress: ProgressHandler? = nil
    ) async -> [HardlinkGroup] {
        await findHardlinks(in: tree, useLinkCountFastPath: tree.linkCountsCaptured, progress: progress)
    }

    /// Internal seam so tests can force the full-grouping path on a scanned tree and pin
    /// fast-path ≡ full-path equivalence.
    func findHardlinks(
        in tree: FileTree,
        useLinkCountFastPath: Bool,
        progress: ProgressHandler? = nil
    ) async -> [HardlinkGroup] {
        // Take a snapshot so we can walk all nodes lock-free.
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()

        // Collect indices of all non-directory file nodes.
        var fileIndices: [UInt32] = []
        fileIndices.reserveCapacity(nodes.count)
        for i in 0..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory else { continue }
            fileIndices.append(UInt32(i))
        }

        guard !fileIndices.isEmpty else { return [] }
        await progress?(0, fileIndices.count)

        func path(for nodeIndex: UInt32) -> String {
            FileTree.pathFromSnapshot(
                at: nodeIndex,
                nodes: nodes,
                stringPool: stringPool,
                rootPath: rootPath
            )
        }

        // Fast path: the scanner recorded link counts, so only flagged files can be
        // hardlinks — group just those, no per-file batching or filesystem fallback.
        // Progress keeps the same contract as the full path (total = all files); the
        // pass is effectively instant, so it reports start and completion only.
        if useLinkCountFastPath {
            var flaggedGroups: [DevIno: [(nodeIndex: UInt32, fileSize: UInt64)]] = [:]
            for i in fileIndices {
                let node = nodes[Int(i)]
                guard node.hasMultipleHardlinks else { continue }
                flaggedGroups[DevIno(dev: node.device, ino: node.inode), default: []]
                    .append((nodeIndex: i, fileSize: node.fileSize))
            }
            await progress?(fileIndices.count, fileIndices.count)
            return Self.buildResults(from: flaggedGroups, path: path)
        }

        // We'll collect node indices first so we only materialize paths for real groups.
        var groups: [DevIno: [(nodeIndex: UInt32, fileSize: UInt64)]] = [:]
        groups.reserveCapacity(fileIndices.count / 4)

        // Process in batches via TaskGroup. Most scanned trees already have device/inode
        // metadata, so this becomes a pure in-memory grouping pass; the fallback path only
        // touches the filesystem for nodes missing identity data.
        let batchSize = 512
        struct BatchResult {
            let members: [(DevIno, UInt32, UInt64)]
        }

        // GCD timer for progress — immune to cooperative pool starvation.
        let hardlinkCounter = ProgressCounter()
        let hardlinkTimer = DeterminateProgressTimer(
            total: fileIndices.count,
            counter: hardlinkCounter,
            progress: progress
        )

        let batchResults: [BatchResult] = await withTaskGroup(
            of: BatchResult.self,
            returning: [BatchResult].self
        ) { group in
            for batchStart in stride(from: 0, to: fileIndices.count, by: batchSize) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + batchSize, fileIndices.count)
                let batch = fileIndices[batchStart..<batchEnd]
                group.addTask {
                    guard !Task.isCancelled else {
                        return BatchResult(members: [])
                    }
                    var results: [(DevIno, UInt32, UInt64)] = []
                    results.reserveCapacity(batch.count)
                    for nodeIndex in batch {
                        guard !Task.isCancelled else { break }
                        let node = nodes[Int(nodeIndex)]
                        if node.inode != 0 || node.device != 0 {
                            let key = DevIno(dev: node.device, ino: node.inode)
                            results.append((key, nodeIndex, node.fileSize))
                        } else {
                            let nodePath = path(for: nodeIndex)
                            var st = Darwin.stat()
                            guard lstat(nodePath, &st) == 0 else {
                                hardlinkCounter.add(1)
                                continue
                            }
                            let key = DevIno(dev: st.st_dev, ino: st.st_ino)
                            let fileSize = UInt64(bitPattern: Int64(st.st_size))
                            results.append((key, nodeIndex, fileSize))
                        }
                        hardlinkCounter.add(1)
                    }
                    return BatchResult(members: results)
                }
            }

            var all: [BatchResult] = []
            for await batch in group {
                all.append(batch)
            }
            return all
        }

        hardlinkTimer.stop()
        await progress?(fileIndices.count, fileIndices.count)

        // Merge batch results into groups dict.
        for batch in batchResults {
            for (key, nodeIndex, fileSize) in batch.members {
                groups[key, default: []].append((nodeIndex: nodeIndex, fileSize: fileSize))
            }
        }

        return Self.buildResults(from: groups, path: path)
    }

    /// Shared tail for both paths: keep 2+-member groups, materialize sorted paths,
    /// sort by extra link bytes descending (most impactful first).
    private static func buildResults(
        from groups: [DevIno: [(nodeIndex: UInt32, fileSize: UInt64)]],
        path: (UInt32) -> String
    ) -> [HardlinkGroup] {
        var results: [HardlinkGroup] = []
        for (key, members) in groups {
            guard members.count >= 2 else { continue }
            let paths = members.map { path($0.nodeIndex) }.sorted()
            let fileSize = members.first?.fileSize ?? 0
            results.append(HardlinkGroup(
                inode: key.ino,
                device: UInt32(bitPattern: key.dev),
                fileSize: fileSize,
                paths: paths
            ))
        }
        results.sort { $0.extraLinkBytes > $1.extraLinkBytes }
        return results
    }
}

/// Hashable (dev, inode) identity shared by both grouping paths.
private struct DevIno: Hashable {
    let dev: Int32
    let ino: UInt64
}

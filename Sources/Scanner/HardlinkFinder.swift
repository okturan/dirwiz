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
/// reconstructing their paths, and calling lstat(2) to get (st_dev, st_ino) pairs.
///
/// Files sharing the same (device, inode) pair with link count ≥ 2 are grouped.
/// This approach avoids modifying the packed FileNode struct — we do a post-scan
/// pass using the existing path-building infrastructure.
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

        // For each file, call lstat to get its (device, inode).
        // Group by (dev, ino) — files sharing both fields are hardlinks to the same data.

        // Dictionary keyed by a hashable representation of (dev, ino).
        struct DevIno: Hashable {
            let dev: Int32
            let ino: UInt64
        }

        // We'll collect: devino -> [(path, fileSize)]
        var groups: [DevIno: [(path: String, fileSize: UInt64)]] = [:]
        groups.reserveCapacity(fileIndices.count / 4)

        // Process in batches via TaskGroup to get parallelism on lstat calls,
        // which are cheap but benefit from concurrency on large trees.
        let batchSize = 512
        struct BatchResult {
            let members: [(DevIno, UInt32, UInt64, String)] // (key, nodeIndex, fileSize, path)
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
                    var results: [(DevIno, UInt32, UInt64, String)] = []
                    results.reserveCapacity(batch.count)
                    for nodeIndex in batch {
                        guard !Task.isCancelled else { break }
                        let path = FileTree.pathFromSnapshot(
                            at: nodeIndex,
                            nodes: nodes,
                            stringPool: stringPool,
                            rootPath: rootPath
                        )
                        var st = Darwin.stat()
                        guard lstat(path, &st) == 0 else {
                            hardlinkCounter.add(1)
                            continue
                        }
                        hardlinkCounter.add(1)
                        // Only interested in files with more than one hard link.
                        guard st.st_nlink > 1 else { continue }
                        let key = DevIno(dev: st.st_dev, ino: st.st_ino)
                        let fileSize = UInt64(bitPattern: Int64(st.st_size))
                        results.append((key, nodeIndex, fileSize, path))
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

        // Merge batch results into groups dict, using the stored path from each result.
        for batch in batchResults {
            for (key, _, fileSize, path) in batch.members {
                groups[key, default: []].append((path: path, fileSize: fileSize))
            }
        }

        // Build HardlinkGroup results — only keep groups with 2+ paths.
        var results: [HardlinkGroup] = []
        for (key, members) in groups {
            guard members.count >= 2 else { continue }
            // Reuse the paths already computed during the lstat batch pass.
            let paths = members.map(\.path).sorted()
            let fileSize = members.first?.fileSize ?? 0
            let hardlinkGroup = HardlinkGroup(
                inode: key.ino,
                device: UInt32(bitPattern: key.dev),
                fileSize: fileSize,
                paths: paths
            )
            results.append(hardlinkGroup)
        }

        // Sort by extra link bytes descending (most impactful first).
        results.sort { $0.extraLinkBytes > $1.extraLinkBytes }
        return results
    }
}

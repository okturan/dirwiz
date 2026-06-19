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
/// For scan results that don't carry identity metadata (for example, manually
/// assembled trees in tests), the finder falls back to `lstat`.
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

        // Dictionary keyed by a hashable representation of (dev, ino).
        struct DevIno: Hashable {
            let dev: Int32
            let ino: UInt64
        }

        // We'll collect node indices first so we only materialize paths for real groups.
        var groups: [DevIno: [(nodeIndex: UInt32, fileSize: UInt64)]] = [:]
        groups.reserveCapacity(fileIndices.count / 4)

        func path(for nodeIndex: UInt32) -> String {
            FileTree.pathFromSnapshot(
                at: nodeIndex,
                nodes: nodes,
                stringPool: stringPool,
                rootPath: rootPath
            )
        }

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

        // Build HardlinkGroup results — only keep groups with 2+ paths.
        var results: [HardlinkGroup] = []
        for (key, members) in groups {
            guard members.count >= 2 else { continue }
            let paths = members.map { path(for: $0.nodeIndex) }.sorted()
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

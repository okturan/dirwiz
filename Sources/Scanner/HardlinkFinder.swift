import Foundation

// MARK: - HardlinkGroup

/// A group of files that all share the same inode (i.e., are hardlinks to the same data).
public struct HardlinkGroup: Identifiable, Sendable {
    public let id: UUID
    public let inode: UInt64
    public let device: UInt32
    public let fileSize: UInt64
    public let paths: [String]

    /// Disk space that would be recovered if all but one hardlink were removed.
    /// Note: removing a hardlink only unlinks a directory entry — the data is freed
    /// only when the last link is removed.
    public var wastedSpace: UInt64 {
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

    public init() {}

    // MARK: - Public API

    /// Find all hardlink groups in the given FileTree.
    ///
    /// - Parameter tree: The scanned file tree to inspect.
    /// - Returns: Array of HardlinkGroup sorted by wastedSpace descending,
    ///            containing only groups with 2 or more paths.
    public func findHardlinks(in tree: FileTree) async -> [HardlinkGroup] {
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

        // For each file, call lstat to get its (device, inode).
        // Group by (dev, ino) — files sharing both fields are hardlinks to the same data.
        typealias InodeKey = (dev: Int32, ino: UInt64)

        // Dictionary keyed by a hashable representation of (dev, ino).
        struct DevIno: Hashable {
            let dev: Int32
            let ino: UInt64
        }

        // We'll collect: devino -> [(nodeIndex, fileSize)]
        var groups: [DevIno: [(index: UInt32, fileSize: UInt64)]] = [:]
        groups.reserveCapacity(fileIndices.count / 4)

        // Process in batches via TaskGroup to get parallelism on lstat calls,
        // which are cheap but benefit from concurrency on large trees.
        let batchSize = 512
        typealias BatchResult = [(DevIno, UInt32, UInt64)] // (key, nodeIndex, fileSize)

        let batchResults: [BatchResult] = await withTaskGroup(
            of: BatchResult.self,
            returning: [BatchResult].self
        ) { group in
            for batchStart in stride(from: 0, to: fileIndices.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, fileIndices.count)
                let batch = fileIndices[batchStart..<batchEnd]
                group.addTask {
                    var results: BatchResult = []
                    results.reserveCapacity(batch.count)
                    for nodeIndex in batch {
                        let path = FileTree.pathFromSnapshot(
                            at: nodeIndex,
                            nodes: nodes,
                            stringPool: stringPool,
                            rootPath: rootPath
                        )
                        var st = Darwin.stat()
                        // Use lstat so we get the link's own inode (not target for symlinks,
                        // but we only process files flagged as non-directory anyway).
                        guard lstat(path, &st) == 0 else { continue }
                        // Only interested in files with more than one hard link.
                        guard st.st_nlink > 1 else { continue }
                        let key = DevIno(dev: st.st_dev, ino: st.st_ino)
                        let fileSize = UInt64(bitPattern: Int64(st.st_size))
                        results.append((key, nodeIndex, fileSize))
                    }
                    return results
                }
            }

            var all: [BatchResult] = []
            for await batch in group {
                all.append(batch)
            }
            return all
        }

        // Merge batch results into groups dict.
        for batch in batchResults {
            for (key, nodeIndex, fileSize) in batch {
                groups[key, default: []].append((index: nodeIndex, fileSize: fileSize))
            }
        }

        // Build HardlinkGroup results — only keep groups with 2+ paths.
        var results: [HardlinkGroup] = []
        for (key, members) in groups {
            guard members.count >= 2 else { continue }
            let paths = members.map { member in
                FileTree.pathFromSnapshot(
                    at: member.index,
                    nodes: nodes,
                    stringPool: stringPool,
                    rootPath: rootPath
                )
            }.sorted()
            let fileSize = members.first?.fileSize ?? 0
            let hardlinkGroup = HardlinkGroup(
                inode: key.ino,
                device: UInt32(bitPattern: key.dev),
                fileSize: fileSize,
                paths: paths
            )
            results.append(hardlinkGroup)
        }

        // Sort by wasted space descending (most impactful first).
        results.sort { $0.wastedSpace > $1.wastedSpace }
        return results
    }
}

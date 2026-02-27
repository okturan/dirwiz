import Foundation
import Synchronization

// MARK: - Full Disk Access Detection

/// Check if Full Disk Access has been granted by probing known protected paths.
/// Tests multiple locations to avoid false negatives (e.g., Safari not installed).
public func checkFullDiskAccess() -> Bool {
    let home = NSHomeDirectory()
    let protectedPaths = [
        home + "/Library/Safari/Bookmarks.plist",
        home + "/Library/Mail",
        home + "/Library/Messages",
        home + "/Library/Cookies",
    ]
    return protectedPaths.contains { access($0, R_OK) == 0 }
}

// MARK: - Bundle Extension Set

private let kBundleExtensions: Set<String> = [
    ".app", ".framework", ".xcarchive", ".xcodeproj", ".xcworkspace",
    ".kext", ".plugin", ".bundle", ".docset", ".xpc",
    ".qlgenerator", ".mdimporter", ".prefpane", ".driver"
]

private func isBundleName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return kBundleExtensions.contains(where: { lower.hasSuffix($0) })
}

// MARK: - Inode Key

/// Proper composite key for (dev, inode) pairs — avoids XOR hash collisions.
private struct InodeKey: Hashable, Sendable {
    let dev: Int32
    let inode: UInt64
}

// MARK: - Visited Directory Tracker

/// Thread-safe set tracking visited (dev, inode) pairs to avoid firmlink/hardlink loops.
private final class VisitedDirectories: Sendable {
    private let seen = Mutex(Set<InodeKey>())

    /// Returns true if this is the first time seeing this (dev, inode) pair.
    func insert(dev: Int32, inode: UInt64) -> Bool {
        let key = InodeKey(dev: dev, inode: inode)
        return seen.withLock { $0.insert(key).inserted }
    }
}

// MARK: - FileScanner

public final class FileScanner: @unchecked Sendable {

    private let cancelState = Mutex(false)
    private let scanQueue = Mutex<OperationQueue?>(nil)
    let filesystem: FilesystemProvider

    public init(filesystem: FilesystemProvider = RealFilesystemProvider()) {
        self.filesystem = filesystem
    }

    /// Cancel an in-progress scan. Safe to call from any thread.
    /// Immediately drops queued-but-not-started operations.
    public func cancel() {
        cancelState.withLock { $0 = true }
        scanQueue.withLock { $0?.cancelAllOperations() }
    }

    private var isCancelled: Bool {
        cancelState.withLock { $0 }
    }

    // MARK: - Public API

    /// Scan the filesystem at `path`, returning the tree.
    /// The tree is populated incrementally — assign it to your UI state before awaiting
    /// this method if you want live updates.
    /// Pass the returned FileTree to the UI immediately; it's populated in-place during scan.
    public func scan(path: String, progress: ScanProgress, tree: FileTree) async {
        // Estimate total items using inode counts (blocking I/O, done off main thread).
        var estimatedItems = 0
        if let sf = filesystem.volumeStats(forPath: path) {
            let usedInodes = max(0, Int64(sf.totalFiles) - Int64(sf.freeFiles))
            if usedInodes > 0 {
                estimatedItems = Int(clamping: usedInodes)
            }

            // Scanning "/" follows firmlinks into the Data volume; include its inode usage too.
            if path == "/" {
                if let dataSF = filesystem.volumeStats(forPath: "/System/Volumes/Data") {
                    let dataUsedInodes = max(0, Int64(dataSF.totalFiles) - Int64(dataSF.freeFiles))
                    if dataUsedInodes > 0 {
                        estimatedItems += Int(clamping: dataUsedInodes)
                    }
                }
            }
        }

        let estimatedItemsSnapshot = estimatedItems
        await MainActor.run {
            progress.reset()
            progress.isScanning = true
            if estimatedItemsSnapshot > 0 {
                progress.estimatedTotalItems = estimatedItemsSnapshot
            }
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Store scan root path for correct absolute path reconstruction.
        tree.setRootPath(path)

        // Detect volume case sensitivity using getattrlist ATTR_VOL_CAPABILITIES.
        // On case-sensitive APFS, we skip lowercasing file names to avoid merging
        // directories that differ only in case (e.g., "Build" vs "build").
        do {
            var volAttrList = attrlist()
            volAttrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            volAttrList.volattr = attrgroup_t(ATTR_VOL_CAPABILITIES)

            struct VolCapBuf {
                var length: UInt32 = 0
                var caps: vol_capabilities_attr_t = vol_capabilities_attr_t()
            }
            var volBuf = VolCapBuf()
            if getattrlist(path, &volAttrList, &volBuf, MemoryLayout<VolCapBuf>.size, 0) == 0 {
                let valid = volBuf.caps.valid.0
                let caps = volBuf.caps.capabilities.0
                let caseSensitive = (valid & UInt32(VOL_CAP_FMT_CASE_SENSITIVE)) != 0
                    && (caps & UInt32(VOL_CAP_FMT_CASE_SENSITIVE)) != 0
                tree.setCaseSensitivity(caseSensitive)
            }
        }

        // Add root node
        let rootName = (path as NSString).lastPathComponent
        var rootNode = FileNode()
        rootNode.isDirectory = true
        tree.addNode(rootNode, name: rootName.isEmpty ? path : rootName)

        // Visited directory tracker (prevents firmlink/hardlink double-counting)
        let visited = VisitedDirectories()

        // Mark root as visited
        if let di = filesystem.deviceAndInode(forPath: path) {
            _ = visited.insert(dev: di.device, inode: di.inode)
        }

        // Determine network-FS status for queue concurrency.
        let isNetworkFS: Bool
        if let sf = filesystem.volumeStats(forPath: path) {
            isNetworkFS = sf.filesystemType == "smbfs"
                || sf.filesystemType == "nfs"
                || sf.filesystemType == "afpfs"
                || sf.filesystemType == "webdavfs"
        } else {
            isNetworkFS = false
        }

        // Set up the operation queue for parallel directory scanning.
        // Reduce concurrency for network/rotational media to avoid seek thrashing.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = isNetworkFS ? 4 : 32
        scanQueue.withLock { $0 = queue }
        defer { scanQueue.withLock { $0 = nil } }
        queue.qualityOfService = .userInitiated

        // Throttle progress updates
        let progressThrottle = Mutex(CFAbsoluteTime(0))

        @Sendable
        func maybeUpdateProgress(currentDir: String) {
            let now = CFAbsoluteTimeGetCurrent()
            let shouldUpdate = progressThrottle.withLock { lastUpdate -> Bool in
                let should = (now - lastUpdate) >= 0.25
                if should { lastUpdate = now }
                return should
            }

            if shouldUpdate {
                let elapsed = now - startTime
                progress.updateCurrentPath(currentDir)
                Task { await MainActor.run {
                    progress.elapsedTime = elapsed
                    progress.publishCounters()
                } }
            }
        }

        // DispatchGroup to track outstanding work
        let group = DispatchGroup()

        @Sendable
        func enqueueDirectory(dirPath: String, parentIndex: UInt32) {
            guard !self.isCancelled else { return }
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                guard !self.isCancelled else { return }
                self.scanDirectory(
                    dirPath: dirPath,
                    parentIndex: parentIndex,
                    tree: tree,
                    progress: progress,
                    visited: visited,
                    enqueue: enqueueDirectory,
                    maybeUpdateProgress: maybeUpdateProgress
                )
            }
        }

        enqueueDirectory(dirPath: path, parentIndex: 0)

        // Wait for all operations to finish.
        // Uses GCD (not Task.detached) because group.wait() is blocking
        // and must not occupy a cooperative thread pool thread.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                group.wait()
                continuation.resume()
            }
        }

        // queue is cleaned up via defer above

        // Propagate sizes bottom-up in a single O(n) pass.
        // During scanning, each node stores only its own direct size (files) or bundle size.
        // This replaces per-directory accumulateSize() calls that walked the parent chain
        // under lock, causing heavy contention with 32 concurrent threads.
        tree.propagateSizes()

        // Final sort by size descending
        tree.sortAllChildren()

        // Finalize progress — publish final counters before marking complete
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let wasCancelled = isCancelled
        await MainActor.run {
            progress.publishCounters(forceLayoutRevision: true)
            progress.elapsedTime = totalElapsed
            progress.isScanning = false
            progress.scanComplete = true
            if wasCancelled {
                progress.isCancelled = true
            }
        }
    }

    // MARK: - Directory Scan (single directory)

    private func scanDirectory(
        dirPath: String,
        parentIndex: UInt32,
        tree: FileTree,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        maybeUpdateProgress: @escaping @Sendable (String) -> Void
    ) {
        guard !isCancelled else { return }
        maybeUpdateProgress(dirPath)

        // nil means open() failed (permission denied, etc.) — matches original behaviour.
        guard let rawEntries = filesystem.listDirectory(path: dirPath) else {
            progress.incrementSkippedDirectories()
            return
        }

        // Collect all children in this directory
        var children: [(node: FileNode, name: String)] = []
        var subdirs: [(name: String, childIndex: Int, dev: Int32, inode: UInt64)] = []
        var bundleDirs: [(name: String, childIndex: Int)] = []

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        for rawEntry in rawEntries {
            guard !isCancelled else { break }

            let entryName = rawEntry.name
            guard !entryName.isEmpty, entryName != ".", entryName != ".." else { continue }

            // Skip symlinks entirely — following them causes double-counting and potential
            // infinite loops. See original FileScanner for detailed rationale.
            guard !rawEntry.isSymlink else { continue }

            let isDir = rawEntry.isDirectory
            let modDate = rawEntry.modifiedDate

            var dataLength: UInt64 = 0
            var allocSize: UInt64 = 0
            if !isDir {
                dataLength = rawEntry.fileSize
                allocSize  = rawEntry.allocatedSize
            }

            // Build FileNode
            var node = FileNode()
            node.isDirectory = isDir
            node.fileSize = isDir ? 0 : dataLength
            node.allocatedSize = isDir ? 0 : allocSize
            node.modifiedDate = modDate
            if !isDir {
                node.extensionHash = extensionHash(entryName)
            }

            // Detect bundles: mark as opaque leaves and skip recursive enqueue.
            let isBundle = isDir && isBundleName(entryName)
            if isBundle {
                node.isBundle = true
            }

            let childLocalIndex = children.count
            children.append((node: node, name: entryName))

            if isDir {
                if isBundle {
                    bundleDirs.append((name: entryName, childIndex: childLocalIndex))
                } else {
                    subdirs.append((name: entryName, childIndex: childLocalIndex,
                                    dev: rawEntry.device, inode: rawEntry.inode))
                }
                dirCount += 1
            } else {
                totalFileSize += dataLength
                totalAllocatedSize += allocSize
                fileCount += 1
            }
        }

        // Update progress counters
        if fileCount > 0 {
            progress.incrementFiles(count: fileCount, size: totalFileSize, allocatedSize: totalAllocatedSize)
        }
        if dirCount > 0 {
            progress.incrementDirectories(count: dirCount)
        }

        // Batch-add all children to the tree
        guard !children.isEmpty else { return }
        let firstChildIndex = tree.addChildren(children, parentIndex: parentIndex)

        // Compute sizes for bundle directories that we intentionally do not recurse into.
        for bundle in bundleDirs {
            guard !isCancelled else { break }
            let bundlePath = dirPath + "/" + bundle.name
            let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                path: bundlePath,
                isCancelled: { self.isCancelled }
            )
            guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
            let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
            tree.updateNode(at: bundleTreeIndex) { node in
                node.fileSize = bundleFileSize
                node.allocatedSize = bundleAllocatedSize
            }
        }

        // Enqueue subdirectories — skip already-visited (dev, inode) pairs (firmlinks, hardlinks)
        for subdir in subdirs {
            guard !isCancelled else { break }
            guard visited.insert(dev: subdir.dev, inode: subdir.inode) else {
                continue // Already visited this directory via another path (firmlink)
            }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
            let subdirPath = dirPath + "/" + subdir.name
            enqueue(subdirPath, childTreeIndex)
        }
    }
}

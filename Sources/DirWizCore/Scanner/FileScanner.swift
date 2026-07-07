import Foundation
import Synchronization
import os

private let scanLog = Logger(subsystem: "com.dirwiz", category: "FileScanner")

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
    "app", "framework", "xcarchive", "xcodeproj", "xcworkspace",
    "kext", "plugin", "bundle", "docset", "xpc",
    "qlgenerator", "mdimporter", "prefpane", "driver"
]
private let kBundleExtensionHashes: Set<UInt32> = Set(kBundleExtensions.map { extensionHash("x.\($0)") })

private func isBundleName(_ name: String) -> Bool {
    kBundleExtensionHashes.contains(extensionHash(name))
}

private func isBundleName(_ nameBytes: UnsafeBufferPointer<UInt8>) -> Bool {
    kBundleExtensionHashes.contains(extensionHash(nameBytes))
}

private func appendPathComponent(_ parent: String, _ child: String) -> String {
    if parent == "/" { return "/" + child }
    var path = String()
    path.reserveCapacity(parent.utf8.count + child.utf8.count + 1)
    path += parent
    path += "/"
    path += child
    return path
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

private struct DirectoryWorkItem: Sendable {
    let path: String
    let parentIndex: UInt32
}

private final class DirectoryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [DirectoryWorkItem] = []
    private var active = 0
    private var closed = false

    func enqueue(path: String, parentIndex: UInt32) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        pending.append(DirectoryWorkItem(path: path, parentIndex: parentIndex))
        condition.signal()
    }

    func next() -> DirectoryWorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !closed {
            if active <= 0 {
                closed = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
        guard !pending.isEmpty else { return nil }
        active += 1
        return pending.removeLast()
    }

    func complete() {
        condition.lock()
        defer { condition.unlock() }
        active -= 1
        if pending.isEmpty && active <= 0 {
            closed = true
            condition.broadcast()
        }
    }

    func cancel() {
        condition.lock()
        pending.removeAll(keepingCapacity: true)
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct RawScanScratch {
    var children: [EncodedFileNode] = []
    var namePool = Data()
    var subdirs: [(nameOffset: Int, nameLength: Int, childIndex: Int, dev: Int32, inode: UInt64)] = []
    var bundleDirs: [(nameOffset: Int, nameLength: Int, childIndex: Int)] = []

    init() {
        children.reserveCapacity(32)
        namePool.reserveCapacity(1024)
        subdirs.reserveCapacity(8)
        bundleDirs.reserveCapacity(2)
    }

    mutating func reset() {
        children.removeAll(keepingCapacity: true)
        namePool.removeAll(keepingCapacity: true)
        subdirs.removeAll(keepingCapacity: true)
        bundleDirs.removeAll(keepingCapacity: true)
    }
}

private final class DeferredTreeBuilder: @unchecked Sendable {
    private struct State: Sendable {
        var nextIndex: UInt32 = 1
        var childRanges: [UInt32: (first: UInt32, count: UInt32)] = [:]
    }

    private let state = Mutex(State())

    func reserveChildren(parentIndex: UInt32, count: Int) -> UInt32 {
        state.withLock { state in
            let firstIndex = state.nextIndex
            state.nextIndex &+= UInt32(count)
            state.childRanges[parentIndex] = (first: firstIndex, count: UInt32(count))
            return firstIndex
        }
    }

    func snapshot() -> (totalNodeCount: Int, childRanges: [UInt32: (first: UInt32, count: UInt32)]) {
        state.withLock { state in
            (totalNodeCount: Int(state.nextIndex), childRanges: state.childRanges)
        }
    }
}

private struct RawScanArena {
    var nodes: [IndexedEncodedFileNode] = []
    var namePool = Data()

    init() {
        nodes.reserveCapacity(8192)
        namePool.reserveCapacity(256 * 1024)
    }

    var isEmpty: Bool { nodes.isEmpty }

    mutating func append(
        children: [EncodedFileNode],
        localNamePool: Data,
        firstIndex: UInt32,
        parentIndex: UInt32
    ) {
        localNamePool.withUnsafeBytes { rawPool in
            let pool = rawPool.bindMemory(to: UInt8.self)
            for localIndex in children.indices {
                var node = children[localIndex].node
                node.parentIndex = parentIndex

                let child = children[localIndex]
                let sourceOffset = child.nameOffset
                let available = sourceOffset >= 0 && sourceOffset < pool.count
                    ? min(child.nameLength, pool.count - sourceOffset)
                    : 0
                let arenaOffset = namePool.count
                let length = min(available, Int(UInt16.max))

                if let base = pool.baseAddress, length > 0 {
                    namePool.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: sourceOffset), count: length))
                }

                nodes.append(IndexedEncodedFileNode(
                    index: firstIndex + UInt32(localIndex),
                    node: node,
                    nameOffset: arenaOffset,
                    nameLength: length
                ))
            }
        }
    }

    func export() -> FileTreeArena {
        FileTreeArena(nodes: nodes, namePool: namePool)
    }
}

public struct BundleSizeResolutionReport: Sendable {
    public let bundlesFound: Int
    public let bundlesResolved: Int
    public let totalFileSize: UInt64
    public let totalAllocatedSize: UInt64
    public let wasCancelled: Bool
}

// MARK: - FileScanner

public final class FileScanner: @unchecked Sendable {

    private let cancelState = Mutex(false)
    private let directoryWorkQueue = Mutex<DirectoryWorkQueue?>(nil)
    private let computeBundleSizes: Bool
    private let deferTreeMaterialization: Bool
    let filesystem: FilesystemProvider

    public init(
        filesystem: FilesystemProvider = RealFilesystemProvider(),
        computeBundleSizes: Bool = ProcessInfo.processInfo.environment["DIRWIZ_SKIP_BUNDLE_SIZES"] != "1",
        deferTreeMaterialization: Bool = ProcessInfo.processInfo.environment["DIRWIZ_DEFER_TREE"] != "0"
    ) {
        self.filesystem = filesystem
        self.computeBundleSizes = computeBundleSizes
        self.deferTreeMaterialization = deferTreeMaterialization
    }

    /// Cancel an in-progress scan. Safe to call from any thread.
    /// Immediately drops queued-but-not-started operations.
    public func cancel() {
        cancelState.withLock { $0 = true }
        directoryWorkQueue.withLock { $0?.cancel() }
    }

    private var isCancelled: Bool {
        cancelState.withLock { $0 }
    }

    // MARK: - Public API

    /// Resolve opaque bundle leaf sizes after a fast scan that skipped inline bundle sizing.
    ///
    /// The initial scanner pass can treat bundles as zero-sized opaque leaves to make the
    /// tree usable sooner. This method walks only those bundle leaves, computes their
    /// recursive sizes, then applies exact deltas to the tree's ancestor totals.
    public func resolveDeferredBundleSizes(in tree: FileTree) async -> BundleSizeResolutionReport {
        let workItems = tree.bundleSizeCandidates()

        guard !workItems.isEmpty else {
            return BundleSizeResolutionReport(
                bundlesFound: 0,
                bundlesResolved: 0,
                totalFileSize: 0,
                totalAllocatedSize: 0,
                wasCancelled: isCancelled || Task.isCancelled
            )
        }

        struct ResolutionTotals: Sendable {
            var resolved = 0
            var fileSize: UInt64 = 0
            var allocatedSize: UInt64 = 0
        }

        let nextWorkIndex = Mutex(0)
        let totals = Mutex(ResolutionTotals())
        let defaultWorkerCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let workerCount = ProcessInfo.processInfo.environment["DIRWIZ_BUNDLE_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) }
            ?? defaultWorkerCount

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(workerCount, workItems.count) {
                group.addTask {
                    while !self.isCancelled && !Task.isCancelled {
                        let itemIndex = nextWorkIndex.withLock { cursor -> Int? in
                            guard cursor < workItems.count else { return nil }
                            defer { cursor += 1 }
                            return cursor
                        }
                        guard let itemIndex else { return }

                        let item = workItems[itemIndex]
                        let (fileSize, allocatedSize) = self.filesystem.computeBundleSize(
                            path: item.path,
                            isCancelled: { self.isCancelled || Task.isCancelled }
                        )
                        guard !self.isCancelled && !Task.isCancelled else { return }

                        let didApply = tree.setNodeSizeAndPropagate(
                            at: item.index,
                            fileSize: fileSize,
                            allocatedSize: allocatedSize,
                            expectedDevice: item.device,
                            expectedInode: item.inode
                        )
                        guard didApply else { continue }

                        totals.withLock { stats in
                            stats.resolved += 1
                            let fileResult = stats.fileSize.addingReportingOverflow(fileSize)
                            stats.fileSize = fileResult.overflow ? UInt64.max : fileResult.partialValue
                            let allocatedResult = stats.allocatedSize.addingReportingOverflow(allocatedSize)
                            stats.allocatedSize = allocatedResult.overflow ? UInt64.max : allocatedResult.partialValue
                        }
                    }
                }
            }
        }

        let finalTotals = totals.withLock { $0 }
        return BundleSizeResolutionReport(
            bundlesFound: workItems.count,
            bundlesResolved: finalTotals.resolved,
            totalFileSize: finalTotals.fileSize,
            totalAllocatedSize: finalTotals.allocatedSize,
            wasCancelled: isCancelled || Task.isCancelled
        )
    }

    /// Scan the filesystem at `path`, returning the tree.
    /// The tree is populated incrementally — assign it to your UI state before awaiting
    /// this method if you want live updates.
    /// Pass the returned FileTree to the UI immediately; it's populated in-place during scan.
    public func scan(path: String, progress: ScanProgress, tree: FileTree) async {
        // Reset cancellation so a scanner instance can be reused after cancel().
        cancelState.withLock { $0 = false }

        // Estimate total items using inode counts (blocking I/O, done off main thread).
        var estimatedItems = 0
        if let sf = filesystem.volumeStats(forPath: path) {
            let normalizedPath = Self.normalizePath(path)
            let normalizedMountPoint = Self.normalizePath(sf.mountPoint)
            if normalizedPath == normalizedMountPoint {
                // Int64(clamping:) saturates at Int64.max instead of trapping on UInt64 values
                // that exceed Int64.max (e.g. a mock or corrupted statfs result with UInt64.max).
                let usedInodes = max(0, Int64(clamping: sf.totalFiles) - Int64(clamping: sf.freeFiles))
                if usedInodes > 0 {
                    estimatedItems = Int(clamping: usedInodes)
                }

                // Scanning "/" follows firmlinks into the Data volume; include its inode usage too.
                if normalizedPath == "/" {
                    if let dataSF = filesystem.volumeStats(forPath: "/System/Volumes/Data") {
                        let dataUsedInodes = max(0, Int64(clamping: dataSF.totalFiles) - Int64(clamping: dataSF.freeFiles))
                        if dataUsedInodes > 0 {
                            estimatedItems += Int(clamping: dataUsedInodes)
                        }
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
        let displayRootName = rootName.isEmpty ? path : rootName

        // Visited directory tracker (prevents firmlink/hardlink double-counting)
        let visited = VisitedDirectories()

        // Mark root as visited
        if let di = filesystem.deviceAndInode(forPath: path) {
            rootNode.device = di.device
            rootNode.inode = di.inode
            _ = visited.insert(dev: di.device, inode: di.inode)
        }
        _ = tree.addNode(rootNode, name: displayRootName)

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

        // Fixed worker pool for parallel directory scanning. A shared queue avoids
        // creating one Operation object per directory on large trees.
        let workQueue = DirectoryWorkQueue()
        directoryWorkQueue.withLock { $0 = workQueue }
        defer { directoryWorkQueue.withLock { $0 = nil } }
        let defaultWorkerCount = isNetworkFS
            ? 4
            : min(6, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let workerCount = ProcessInfo.processInfo.environment["DIRWIZ_SCAN_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) }
            ?? defaultWorkerCount
        let rawFilesystemForScan = filesystem as? RealFilesystemProvider
        let deferredBuilder = rawFilesystemForScan != nil && deferTreeMaterialization
            ? DeferredTreeBuilder()
            : nil
        let completedArenas = Mutex<[FileTreeArena]>([])

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

        @Sendable
        func enqueueDirectory(dirPath: String, parentIndex: UInt32) {
            guard !self.isCancelled else { return }
            workQueue.enqueue(path: dirPath, parentIndex: parentIndex)
        }

        enqueueDirectory(dirPath: path, parentIndex: 0)

        // Wait for the fixed worker pool to drain all queued directory work.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<workerCount {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let rawFilesystem = rawFilesystemForScan
                    let rawBuffer = rawFilesystem.map { _ in
                        UnsafeMutableRawPointer.allocate(
                            byteCount: RealFilesystemProvider.directoryBufferSize,
                            alignment: 16
                        )
                    }
                    var rawScratch = RawScanScratch()
                    var rawArena = RawScanArena()
                    defer { rawBuffer?.deallocate() }

                    while let item = workQueue.next() {
                        if self.isCancelled {
                            workQueue.complete()
                            continue
                        }
                        self.scanDirectory(
                            dirPath: item.path,
                            parentIndex: item.parentIndex,
                            tree: tree,
                            progress: progress,
                            visited: visited,
                            enqueue: enqueueDirectory,
                            maybeUpdateProgress: maybeUpdateProgress,
                            rawFilesystem: rawFilesystem,
                            rawBuffer: rawBuffer,
                            rawScratch: &rawScratch,
                            deferredBuilder: deferredBuilder,
                            rawArena: &rawArena
                        )
                        workQueue.complete()
                    }
                    if deferredBuilder != nil, !rawArena.isEmpty {
                        let arena = rawArena.export()
                        completedArenas.withLock { $0.append(arena) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }

        if let deferredBuilder {
            let snapshot = deferredBuilder.snapshot()
            let arenas = completedArenas.withLock { $0 }
            tree.replaceContents(
                rootNode: rootNode,
                rootName: displayRootName,
                childRanges: snapshot.childRanges,
                arenas: arenas,
                totalNodeCount: snapshot.totalNodeCount
            )
        }

        // Propagate sizes bottom-up in a single O(n) pass.
        // During scanning, each node stores only its own direct size (files) or bundle size.
        // This replaces per-directory accumulateSize() calls that walked the parent chain
        // under lock, causing heavy contention with 32 concurrent threads.
        tree.propagateSizes()

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
        maybeUpdateProgress: @escaping @Sendable (String) -> Void,
        rawFilesystem: RealFilesystemProvider? = nil,
        rawBuffer: UnsafeMutableRawPointer? = nil,
        rawScratch: inout RawScanScratch,
        deferredBuilder: DeferredTreeBuilder? = nil,
        rawArena: inout RawScanArena
    ) {
        guard !isCancelled else { return }
        maybeUpdateProgress(dirPath)

        if let realFilesystem = rawFilesystem ?? (filesystem as? RealFilesystemProvider) {
            if let deferredBuilder {
                scanDirectoryRawDeferred(
                    filesystem: realFilesystem,
                    dirPath: dirPath,
                    parentIndex: parentIndex,
                    progress: progress,
                    visited: visited,
                    enqueue: enqueue,
                    rawBuffer: rawBuffer,
                    scratch: &rawScratch,
                    builder: deferredBuilder,
                    arena: &rawArena
                )
            } else {
                scanDirectoryRaw(
                    filesystem: realFilesystem,
                    dirPath: dirPath,
                    parentIndex: parentIndex,
                    tree: tree,
                    progress: progress,
                    visited: visited,
                    enqueue: enqueue,
                    rawBuffer: rawBuffer,
                    scratch: &rawScratch
                )
            }
            return
        }

        // Collect all children in this directory
        var children: [(node: FileNode, name: String)] = []
        var subdirs: [(name: String, childIndex: Int, dev: Int32, inode: UInt64)] = []
        var bundleDirs: [(name: String, childIndex: Int)] = []
        children.reserveCapacity(32)
        subdirs.reserveCapacity(8)
        bundleDirs.reserveCapacity(2)

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        // false means open() failed (permission denied, etc.) — matches original behaviour.
        let opened = filesystem.forEachDirectoryEntry(path: dirPath) { rawEntry in
            guard !isCancelled else { return false }

            let entryName = rawEntry.name
            guard !entryName.isEmpty, entryName != ".", entryName != ".." else { return true }

            // Skip symlinks entirely — following them causes double-counting and potential
            // infinite loops. See original FileScanner for detailed rationale.
            guard !rawEntry.isSymlink else { return true }

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
            node.device = rawEntry.device
            node.inode = rawEntry.inode
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
            return true
        }

        guard opened else {
            scanLog.warning("Skipped (permission denied): \(dirPath, privacy: .public)")
            progress.incrementSkippedDirectories()
            return
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
        if computeBundleSizes {
            for bundle in bundleDirs {
                guard !isCancelled else { break }
                let bundlePath = appendPathComponent(dirPath, bundle.name)
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
        }

        // Enqueue subdirectories — skip already-visited (dev, inode) pairs (firmlinks, hardlinks)
        for subdir in subdirs {
            guard !isCancelled else { break }
            guard visited.insert(dev: subdir.dev, inode: subdir.inode) else {
                continue // Already visited this directory via another path (firmlink)
            }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
            let subdirPath = appendPathComponent(dirPath, subdir.name)
            enqueue(subdirPath, childTreeIndex)
        }
    }

    /// Decode a name from a scratch/arena-local name pool by byte offset/length.
    /// Shared by both raw materialization strategies below.
    private static func nameString(in namePool: Data, offset: Int, length: Int) -> String {
        namePool.withUnsafeBytes { rawPool in
            let pool = rawPool.bindMemory(to: UInt8.self)
            guard let base = pool.baseAddress, offset >= 0, offset < pool.count else { return "" }
            let clampedLength = min(length, pool.count - offset)
            return String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset), count: clampedLength), as: UTF8.self)
        }
    }

    /// Shared core for both raw-buffer scan strategies (immediate and deferred
    /// materialization): reads one directory's entries via `forEachRawDirectoryEntry`,
    /// classifies each into file/dir/bundle with size + counter accounting, then hands
    /// the populated scratch buffer to `materialize` — the only variation point.
    ///
    /// `materialize` performs bundle-size computation and writes the children into
    /// their destination (tree or deferred arena) in whichever order that destination
    /// requires (immediate mode publishes to the tree first so the UI sees the entry
    /// sooner, then patches bundle sizes in place; deferred mode has no tree node to
    /// patch later, so it must bake bundle sizes into the scratch children before they
    /// are copied into the arena). It returns the first child index, which this shared
    /// core then uses to enqueue subdirectories — identical in both strategies.
    private func processRawDirectory(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch,
        materialize: (inout RawScanScratch, UInt32) -> UInt32
    ) {
        scratch.reset()

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        let opened: Bool
        if let rawBuffer {
            opened = filesystem.forEachRawDirectoryEntry(
                path: dirPath,
                buffer: rawBuffer,
                bufferSize: RealFilesystemProvider.directoryBufferSize,
                { rawEntry in processRawEntry(rawEntry) }
            )
        } else {
            opened = filesystem.forEachRawDirectoryEntry(path: dirPath) { rawEntry in
                processRawEntry(rawEntry)
            }
        }

        func processRawEntry(_ rawEntry: RawDirectoryEntry) -> Bool {
            guard !isCancelled else { return false }
            let isDir = rawEntry.isDirectory

            var node = FileNode()
            node.isDirectory = isDir
            node.fileSize = isDir ? 0 : rawEntry.fileSize
            node.allocatedSize = isDir ? 0 : rawEntry.allocatedSize
            node.modifiedDate = rawEntry.modifiedDate
            node.device = rawEntry.device
            node.inode = rawEntry.inode
            if !isDir {
                node.extensionHash = extensionHash(rawEntry.nameBytes)
            }

            let isBundle = isDir && isBundleName(rawEntry.nameBytes)
            if isBundle {
                node.isBundle = true
            }

            let nameOffset = scratch.namePool.count
            let nameLength = rawEntry.nameBytes.count
            if let base = rawEntry.nameBytes.baseAddress {
                scratch.namePool.append(contentsOf: UnsafeBufferPointer(start: base, count: nameLength))
            }

            let childLocalIndex = scratch.children.count
            scratch.children.append(EncodedFileNode(
                node: node,
                nameOffset: nameOffset,
                nameLength: nameLength
            ))

            if isDir {
                if isBundle {
                    scratch.bundleDirs.append((nameOffset: nameOffset, nameLength: nameLength, childIndex: childLocalIndex))
                } else {
                    scratch.subdirs.append((
                        nameOffset: nameOffset,
                        nameLength: nameLength,
                        childIndex: childLocalIndex,
                        dev: rawEntry.device,
                        inode: rawEntry.inode
                    ))
                }
                dirCount += 1
            } else {
                totalFileSize += rawEntry.fileSize
                totalAllocatedSize += rawEntry.allocatedSize
                fileCount += 1
            }
            return true
        }

        guard opened else {
            scanLog.warning("Skipped (permission denied): \(dirPath, privacy: .public)")
            progress.incrementSkippedDirectories()
            return
        }

        if fileCount > 0 {
            progress.incrementFiles(count: fileCount, size: totalFileSize, allocatedSize: totalAllocatedSize)
        }
        if dirCount > 0 {
            progress.incrementDirectories(count: dirCount)
        }

        guard !scratch.children.isEmpty else { return }

        let firstChildIndex = materialize(&scratch, parentIndex)

        for subdir in scratch.subdirs {
            guard !isCancelled else { break }
            guard visited.insert(dev: subdir.dev, inode: subdir.inode) else {
                continue
            }
            let subdirName = Self.nameString(in: scratch.namePool, offset: subdir.nameOffset, length: subdir.nameLength)
            guard !subdirName.isEmpty else { continue }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
            let subdirPath = appendPathComponent(dirPath, subdirName)
            enqueue(subdirPath, childTreeIndex)
        }
    }

    private func scanDirectoryRaw(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        tree: FileTree,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch
    ) {
        processRawDirectory(
            filesystem: filesystem,
            dirPath: dirPath,
            parentIndex: parentIndex,
            progress: progress,
            visited: visited,
            enqueue: enqueue,
            rawBuffer: rawBuffer,
            scratch: &scratch
        ) { scratch, parentIndex in
            // Materialize immediately so the tree is visible to readers as soon as
            // possible, then patch bundle sizes into the already-published node in place.
            let firstChildIndex = tree.addChildren(
                encoded: scratch.children,
                namePool: scratch.namePool,
                parentIndex: parentIndex
            )

            if self.computeBundleSizes {
                for bundle in scratch.bundleDirs {
                    guard !self.isCancelled else { break }
                    let bundleName = Self.nameString(in: scratch.namePool, offset: bundle.nameOffset, length: bundle.nameLength)
                    guard !bundleName.isEmpty else { continue }
                    let bundlePath = appendPathComponent(dirPath, bundleName)
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
            }

            return firstChildIndex
        }
    }

    private func scanDirectoryRawDeferred(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch,
        builder: DeferredTreeBuilder,
        arena: inout RawScanArena
    ) {
        processRawDirectory(
            filesystem: filesystem,
            dirPath: dirPath,
            parentIndex: parentIndex,
            progress: progress,
            visited: visited,
            enqueue: enqueue,
            rawBuffer: rawBuffer,
            scratch: &scratch
        ) { scratch, parentIndex in
            // No tree node exists yet to patch after the fact — bundle sizes must be
            // baked into the scratch children before they are copied into the arena.
            if self.computeBundleSizes {
                for bundle in scratch.bundleDirs {
                    guard !self.isCancelled else { break }
                    let bundleName = Self.nameString(in: scratch.namePool, offset: bundle.nameOffset, length: bundle.nameLength)
                    guard !bundleName.isEmpty else { continue }
                    let bundlePath = appendPathComponent(dirPath, bundleName)
                    let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                        path: bundlePath,
                        isCancelled: { self.isCancelled }
                    )
                    guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
                    scratch.children[bundle.childIndex].node.fileSize = bundleFileSize
                    scratch.children[bundle.childIndex].node.allocatedSize = bundleAllocatedSize
                }
            }

            let firstChildIndex = builder.reserveChildren(parentIndex: parentIndex, count: scratch.children.count)
            arena.append(
                children: scratch.children,
                localNamePool: scratch.namePool,
                firstIndex: firstChildIndex,
                parentIndex: parentIndex
            )
            return firstChildIndex
        }
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path == "/" { return "/" }
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

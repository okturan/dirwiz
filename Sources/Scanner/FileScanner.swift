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

// MARK: - getattrlistbulk Attribute Layout

// Attribute request flags — includes DEVID and FILEID for deduplication.
// Attributes are returned in canonical bit order within each group:
//   RETURNED_ATTRS, NAME, DEVID, OBJTYPE, MODTIME, FILEID, then FILE attrs.
private let kRequestedCommonAttrs: attrgroup_t =
    attrgroup_t(ATTR_CMN_RETURNED_ATTRS) |
    attrgroup_t(ATTR_CMN_NAME) |
    attrgroup_t(ATTR_CMN_DEVID) |
    attrgroup_t(ATTR_CMN_OBJTYPE) |
    attrgroup_t(ATTR_CMN_MODTIME) |
    attrgroup_t(ATTR_CMN_FILEID)

private let kRequestedFileAttrs: attrgroup_t =
    attrgroup_t(ATTR_FILE_DATALENGTH) |
    attrgroup_t(ATTR_FILE_ALLOCSIZE)

private let kBufferSize = 128 * 1024 // 128 KB

private let kBundleExtensions: Set<String> = [
    ".app", ".framework", ".xcarchive", ".xcodeproj", ".xcworkspace",
    ".kext", ".plugin", ".bundle", ".docset", ".xpc",
    ".qlgenerator", ".mdimporter", ".prefpane", ".driver"
]

private func isBundleName(_ name: String) -> Bool {
    let lower = name.lowercased()
    return kBundleExtensions.contains(where: { lower.hasSuffix($0) })
}

/// Packed entry layout (64-bit macOS):
///   offset  0: UInt32           length
///   offset  4: attribute_set_t  returned        (5 × UInt32 = 20 bytes)
///   offset 24: attrreference_t  name            (Int32 offset + UInt32 length = 8 bytes)
///   offset 32: dev_t            devid           (Int32 = 4 bytes)
///   offset 36: fsobj_type_t     objtype         (UInt32 = 4 bytes)
///   offset 40: timespec         modtime         (16 bytes on 64-bit)
///   offset 56: uint64_t         fileid          (8 bytes)
///   -- file attributes (only for regular files, canonical bit order) --
///   offset 64: off_t            allocSize       (8 bytes)  ATTR_FILE_ALLOCSIZE   0x004
///   offset 72: off_t            dataLength      (8 bytes)  ATTR_FILE_DATALENGTH  0x200

private let kOffsetName:     Int = 24
private let kOffsetDevID:    Int = 32
private let kOffsetObjType:  Int = 36
private let kOffsetModTime:  Int = 40
private let kOffsetFileID:   Int = 56  // 40 + sizeof(timespec)=16
private let kOffsetFileData: Int = 64  // 56 + sizeof(uint64)=8

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

// MARK: - Entry Parsing Helpers

/// Parse the entry name from a getattrlistbulk packed entry.
private func parseEntryName(from entry: UnsafeRawPointer) -> String {
    let nameRef = entry.advanced(by: kOffsetName)
    let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
    let nameLength = Int(nameRef.advanced(by: 4).loadUnaligned(as: UInt32.self))
    guard nameLength > 1 else { return "" }
    let namePtr = nameRef.advanced(by: nameOffset)
    let data = Data(bytes: namePtr, count: nameLength - 1)
    return String(data: data, encoding: .utf8) ?? ""
}

/// Parse logical data length and allocated size from a file entry.
/// Canonical bit order: ALLOCSIZE (0x004) at offset 64, DATALENGTH (0x200) at offset 72.
private func parseFileSizes(from entry: UnsafeRawPointer) -> (dataLength: UInt64, allocSize: UInt64) {
    let allocSize = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData).loadUnaligned(as: off_t.self)))
    let dataLength = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData + 8).loadUnaligned(as: off_t.self)))
    return (dataLength, allocSize)
}

// MARK: - FileScanner

public final class FileScanner {

    private let cancelState = Mutex(false)

    public init() {}

    /// Cancel an in-progress scan. Safe to call from any thread.
    public func cancel() {
        cancelState.withLock { $0 = true }
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
        var stat = statfs()
        var estimatedItems = 0
        if statfs(path, &stat) == 0 {
            let usedInodes = max(0, Int64(stat.f_files) - Int64(stat.f_ffree))
            if usedInodes > 0 {
                estimatedItems = Int(clamping: usedInodes)
            }

            // Scanning "/" follows firmlinks into the Data volume; include its inode usage too.
            let dataVolumePath = "/System/Volumes/Data"
            if path == "/", statfs(dataVolumePath, &stat) == 0 {
                let dataUsedInodes = max(0, Int64(stat.f_files) - Int64(stat.f_ffree))
                if dataUsedInodes > 0 {
                    estimatedItems += Int(clamping: dataUsedInodes)
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
        var rootStat = Darwin.stat()
        if lstat(path, &rootStat) == 0 {
            _ = visited.insert(dev: rootStat.st_dev, inode: rootStat.st_ino)
        }

        // Set up the operation queue for parallel directory scanning.
        // Reduce concurrency for network/rotational media to avoid seek thrashing.
        let queue = OperationQueue()
        let isNetworkFS: Bool = withUnsafePointer(to: stat.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cstr in
                let name = String(cString: cstr)
                return name == "smbfs" || name == "nfs" || name == "afpfs" || name == "webdavfs"
            }
        }
        queue.maxConcurrentOperationCount = isNetworkFS ? 4 : 32
        queue.qualityOfService = .userInitiated

        // Throttle progress updates
        let progressThrottle = Mutex(CFAbsoluteTime(0))

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
                DispatchQueue.main.async {
                    progress.elapsedTime = elapsed
                    progress.publishCounters()
                }
            }
        }

        // DispatchGroup to track outstanding work
        let group = DispatchGroup()

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

        // Cancel any remaining queued operations
        if isCancelled {
            queue.cancelAllOperations()
        }

        // Propagate sizes bottom-up in a single O(n) pass.
        // During scanning, each node stores only its own direct size (files) or bundle size.
        // This replaces per-directory accumulateSize() calls that walked the parent chain
        // under lock, causing heavy contention with 32 concurrent threads.
        tree.propagateSizes()

        // Final sort by size descending
        tree.sortAllChildren()

        // Finalize progress — publish final counters before marking complete
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        await MainActor.run {
            progress.publishCounters(forceLayoutRevision: true)
            progress.elapsedTime = totalElapsed
            progress.isScanning = false
            progress.scanComplete = true
            if self.isCancelled {
                progress.isCancelled = true
            }
        }
    }

    // MARK: - Directory Scan (single directory with getattrlistbulk)

    private func scanDirectory(
        dirPath: String,
        parentIndex: UInt32,
        tree: FileTree,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping (String, UInt32) -> Void,
        maybeUpdateProgress: @escaping (String) -> Void
    ) {
        guard !isCancelled else { return }
        maybeUpdateProgress(dirPath)

        // Open directory — O_NOFOLLOW prevents following symlinks
        let fd = open(dirPath, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            // Track all failures that cause us to skip a directory (permission denied,
            // I/O errors, too many open files, etc.) so the user knows results are incomplete.
            progress.incrementSkippedDirectories()
            return
        }
        defer { close(fd) }

        // Set up attrlist
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = kRequestedCommonAttrs
        attrList.fileattr = kRequestedFileAttrs

        // Allocate buffer
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: kBufferSize, alignment: 16)
        defer { buffer.deallocate() }

        // Collect all children in this directory
        var children: [(node: FileNode, name: String)] = []
        var subdirs: [(name: String, childIndex: Int, dev: Int32, inode: UInt64)] = []
        var bundleDirs: [(name: String, childIndex: Int)] = []

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        // Read entries in a loop
        while !isCancelled {
            let count = getattrlistbulk(fd, &attrList, buffer, kBufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count <= 0 { break }

            let bufferEnd = buffer.advanced(by: kBufferSize)
            var entryPtr = buffer
            for _ in 0..<count {
                let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                guard entryLength > 0, entryLength >= kOffsetFileData else { break } // prevent infinite loop on corrupt data

                let entry = entryPtr

                // Parse name
                let entryName = parseEntryName(from: entry)

                guard !entryName.isEmpty, entryName != ".", entryName != ".." else {
                    entryPtr = entryPtr.advanced(by: entryLength)
                    continue
                }

                // Parse devid
                let devID = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)

                // Parse objtype
                let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                let isDir = (objType == VDIR.rawValue)
                let isSymlink = (objType == VLNK.rawValue)

                // Skip symlinks entirely — following them causes double-counting (the target
                // is already counted at its real location) and potential infinite loops.
                // Symlinks themselves use negligible disk space (a few bytes for the target path).
                // For a disk space analyzer, this is the correct behavior: the user sees where
                // the actual bytes live, not where aliases point.
                guard !isSymlink else {
                    entryPtr = entryPtr.advanced(by: entryLength)
                    continue
                }

                // Parse modtime
                let modTimeSec = entry.advanced(by: kOffsetModTime).loadUnaligned(as: Int.self)
                let modDate = UInt32(clamping: max(0, modTimeSec))

                // Parse fileid (inode)
                let fileID = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)

                // File attributes (only for regular files)
                var dataLength: UInt64 = 0
                var allocSize: UInt64 = 0
                if !isDir {
                    (dataLength, allocSize) = parseFileSizes(from: entry)
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
                        subdirs.append((name: entryName, childIndex: childLocalIndex, dev: devID, inode: fileID))
                    }
                    dirCount += 1
                } else {
                    totalFileSize += dataLength
                    totalAllocatedSize += allocSize
                    fileCount += 1
                }

                let next = entryPtr.advanced(by: entryLength)
                guard next <= bufferEnd else { break }
                entryPtr = next
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
        // Reuse the scanner's buffer (no longer needed for getattrlistbulk above) to avoid
        // a fresh 128KB allocation per bundle.
        // Note: sizes are NOT accumulated up the parent chain here — that's deferred to
        // propagateSizes() after the scan completes, avoiding lock contention from 32 threads.
        for bundle in bundleDirs {
            guard !isCancelled else { break }
            let bundlePath = dirPath + "/" + bundle.name
            let (bundleFileSize, bundleAllocatedSize) = computeBundleSize(path: bundlePath, buffer: buffer)
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

    /// Compute recursive logical/allocated size for an opaque bundle directory.
    /// This performs an internal walk but does not add nodes or recurse in the main scan tree.
    /// Accepts a pre-allocated buffer to avoid a 128KB allocation per bundle.
    private func computeBundleSize(path: String, buffer: UnsafeMutableRawPointer) -> (fileSize: UInt64, allocatedSize: UInt64) {
        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var stack: [String] = [path]
        var seen = Set<InodeKey>()

        var rootStat = Darwin.stat()
        if lstat(path, &rootStat) == 0 {
            seen.insert(InodeKey(dev: rootStat.st_dev, inode: rootStat.st_ino))
        }

        while let currentDir = stack.popLast(), !isCancelled {
            let fd = open(currentDir, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var attrList = attrlist()
            attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrList.commonattr = kRequestedCommonAttrs
            attrList.fileattr = kRequestedFileAttrs


            while !isCancelled {
                let count = getattrlistbulk(fd, &attrList, buffer, kBufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
                if count <= 0 { break }
                let bufferEnd = buffer.advanced(by: kBufferSize)
                var entryPtr = buffer
                for _ in 0..<count {
                    // Check cancellation inside inner loop — large bundles (Xcode ~30GB)
                    // can have thousands of entries and would otherwise block cancel.
                    guard !isCancelled else { break }

                    let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                    guard entryLength > 0, entryLength >= kOffsetFileData else { break }
                    let entry = entryPtr
                    let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                    let isDir = (objType == VDIR.rawValue)
                    let isSymlink = (objType == VLNK.rawValue)

                    let next = entryPtr.advanced(by: entryLength)
                    guard next <= bufferEnd else { break }

                    guard !isSymlink else {
                        entryPtr = next
                        continue
                    }

                    if isDir {
                        let entryName = parseEntryName(from: entry)
                        if !entryName.isEmpty, entryName != ".", entryName != ".." {
                            let devID = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)
                            let fileID = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)
                            if seen.insert(InodeKey(dev: devID, inode: fileID)).inserted {
                                stack.append(currentDir + "/" + entryName)
                            }
                        }
                    } else {
                        let (dataLength, allocSize) = parseFileSizes(from: entry)
                        totalFileSize += dataLength
                        totalAllocatedSize += allocSize
                    }

                    entryPtr = next
                }
            }
        }

        return (totalFileSize, totalAllocatedSize)
    }
}

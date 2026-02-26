import Foundation

// MARK: - Full Disk Access Detection

/// Check if Full Disk Access has been granted by probing a protected file.
public func checkFullDiskAccess() -> Bool {
    let home = NSHomeDirectory()
    let testPath = home + "/Library/Safari/Bookmarks.plist"
    return access(testPath, R_OK) == 0
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
///   -- file attributes (only for regular files) --
///   offset 64: off_t            dataLength      (8 bytes)
///   offset 72: off_t            allocSize       (8 bytes)

private let kOffsetName:     Int = 24
private let kOffsetDevID:    Int = 32
private let kOffsetObjType:  Int = 36
private let kOffsetModTime:  Int = 40
private let kOffsetFileID:   Int = 56  // 40 + sizeof(timespec)=16
private let kOffsetFileData: Int = 64  // 56 + sizeof(uint64)=8

// MARK: - Visited Directory Tracker

/// Thread-safe set tracking visited (dev, inode) pairs to avoid firmlink/hardlink loops.
private final class VisitedDirectories: @unchecked Sendable {
    private var seen = Set<UInt64>()
    private let lock = NSLock()

    /// Returns true if this is the first time seeing this (dev, inode) pair.
    func insert(dev: Int32, inode: UInt64) -> Bool {
        // Combine dev and inode into a single key. dev_t is 32 bits.
        let key = (UInt64(bitPattern: Int64(dev)) << 32) ^ inode
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }
}

// MARK: - FileScanner

public final class FileScanner {

    private var cancelled = false
    private let cancelLock = NSLock()

    public init() {}

    /// Cancel an in-progress scan. Safe to call from any thread.
    public func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    // MARK: - Public API

    /// Scan the filesystem at `path`, returning the tree.
    /// The tree is populated incrementally — assign it to your UI state before awaiting
    /// this method if you want live updates.
    /// Pass the returned FileTree to the UI immediately; it's populated in-place during scan.
    public func scan(path: String, progress: ScanProgress, tree: FileTree) async {
        cancelLock.lock()
        cancelled = false
        cancelLock.unlock()
        progress.reset()
        progress.isScanning = true
        let startTime = CFAbsoluteTimeGetCurrent()

        // Estimate total items using used inode counts for determinate progress.
        var stat = statfs()
        if statfs(path, &stat) == 0 {
            let usedInodes = max(0, Int64(stat.f_files) - Int64(stat.f_ffree))
            if usedInodes > 0 {
                progress.estimatedTotalItems = Int(clamping: usedInodes)
            }

            // Scanning "/" follows firmlinks into the Data volume; include its inode usage too.
            let dataVolumePath = "/System/Volumes/Data"
            if path == "/", statfs(dataVolumePath, &stat) == 0 {
                let dataUsedInodes = max(0, Int64(stat.f_files) - Int64(stat.f_ffree))
                if dataUsedInodes > 0 {
                    progress.estimatedTotalItems += Int(clamping: dataUsedInodes)
                }
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

        // Set up the operation queue for parallel directory scanning
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 32
        queue.qualityOfService = .userInitiated

        // Throttle progress updates
        let lastProgressUpdate = NSLock()
        var lastUpdateTime: CFAbsoluteTime = 0

        func maybeUpdateProgress(currentDir: String) {
            let now = CFAbsoluteTimeGetCurrent()
            lastProgressUpdate.lock()
            let shouldUpdate = (now - lastUpdateTime) >= 0.25
            if shouldUpdate { lastUpdateTime = now }
            lastProgressUpdate.unlock()

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

        // Wait for all operations to finish
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

        // Final sort by size descending
        tree.sortAllChildren()

        // Finalize progress — publish final counters before marking complete
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        await MainActor.run {
            progress.publishCounters()
            progress.elapsedTime = totalElapsed
            progress.isScanning = false
            progress.scanComplete = true
            if self.isCancelled {
                progress.error = "Scan cancelled"
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
        guard fd >= 0 else { return }
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

            var entryPtr = buffer
            for _ in 0..<count {
                let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                guard entryLength >= kOffsetFileData else { break } // minimum valid entry size

                let entry = entryPtr

                // Parse name
                let nameRef = entry.advanced(by: kOffsetName)
                let nameAttrOffset = Int(nameRef.loadUnaligned(as: Int32.self))
                let nameAttrLength = Int(nameRef.advanced(by: 4).loadUnaligned(as: UInt32.self))

                let namePtr = nameRef.advanced(by: nameAttrOffset)
                let entryName: String
                if nameAttrLength > 1 {
                    let data = Data(bytes: namePtr, count: nameAttrLength - 1) // minus null terminator
                    entryName = String(data: data, encoding: .utf8) ?? ""
                } else {
                    entryName = ""
                }

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

                // Skip symlinks entirely — they cause double-counting and loops
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
                    dataLength = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData).loadUnaligned(as: off_t.self)))
                    allocSize = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData + 8).loadUnaligned(as: off_t.self)))
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

                entryPtr = entryPtr.advanced(by: entryLength)
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

        // Accumulate total file sizes up the parent chain
        if totalFileSize > 0 || totalAllocatedSize > 0 {
            tree.accumulateSize(from: firstChildIndex, fileSize: totalFileSize, allocatedSize: totalAllocatedSize)
        }

        // Compute and propagate sizes for bundle directories that we intentionally do not recurse into.
        for bundle in bundleDirs {
            guard !isCancelled else { break }
            let bundlePath = dirPath + "/" + bundle.name
            let (bundleFileSize, bundleAllocatedSize) = computeBundleSize(path: bundlePath)
            guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
            let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
            tree.updateNode(at: bundleTreeIndex) { node in
                node.fileSize = bundleFileSize
                node.allocatedSize = bundleAllocatedSize
            }
            tree.accumulateSize(from: bundleTreeIndex, fileSize: bundleFileSize, allocatedSize: bundleAllocatedSize)
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
    private func computeBundleSize(path: String) -> (fileSize: UInt64, allocatedSize: UInt64) {
        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var stack: [String] = [path]
        var seen = Set<UInt64>()

        var rootStat = Darwin.stat()
        if lstat(path, &rootStat) == 0 {
            let rootKey = (UInt64(bitPattern: Int64(rootStat.st_dev)) << 32) ^ rootStat.st_ino
            seen.insert(rootKey)
        }

        while let currentDir = stack.popLast(), !isCancelled {
            let fd = open(currentDir, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var attrList = attrlist()
            attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrList.commonattr = kRequestedCommonAttrs
            attrList.fileattr = kRequestedFileAttrs

            let buffer = UnsafeMutableRawPointer.allocate(byteCount: kBufferSize, alignment: 16)
            defer { buffer.deallocate() }

            while !isCancelled {
                let count = getattrlistbulk(fd, &attrList, buffer, kBufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
                if count <= 0 { break }
                var entryPtr = buffer
                for _ in 0..<count {
                    let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                    guard entryLength >= kOffsetFileData else { break }
                    let entry = entryPtr
                    let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                    let isDir = (objType == VDIR.rawValue)
                    let isSymlink = (objType == VLNK.rawValue)
                    guard !isSymlink else {
                        entryPtr = entryPtr.advanced(by: entryLength)
                        continue
                    }

                    if isDir {
                        let nameRef = entry.advanced(by: kOffsetName)
                        let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
                        let nameLength = Int(nameRef.advanced(by: 4).loadUnaligned(as: UInt32.self))
                        let namePtr = nameRef.advanced(by: nameOffset)
                        let nameData = Data(bytes: namePtr, count: max(0, nameLength - 1))
                        let entryName = String(data: nameData, encoding: .utf8) ?? ""
                        if !entryName.isEmpty, entryName != ".", entryName != ".." {
                            let devID = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)
                            let fileID = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)
                            let key = (UInt64(bitPattern: Int64(devID)) << 32) ^ fileID
                            if seen.insert(key).inserted {
                                stack.append(currentDir + "/" + entryName)
                            }
                        }
                    } else {
                        let dataLength = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData).loadUnaligned(as: off_t.self)))
                        let allocSize = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData + 8).loadUnaligned(as: off_t.self)))
                        totalFileSize += dataLength
                        totalAllocatedSize += allocSize
                    }

                    entryPtr = entryPtr.advanced(by: entryLength)
                }
            }
        }

        return (totalFileSize, totalAllocatedSize)
    }
}

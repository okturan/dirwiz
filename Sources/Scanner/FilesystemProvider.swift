import Foundation

// MARK: - Directory Entry

/// A single filesystem entry returned by FilesystemProvider.listDirectory.
/// Carries everything FileScanner needs from a getattrlistbulk result.
public struct DirectoryEntry: Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var fileSize: UInt64       // logical bytes (ATTR_FILE_DATALENGTH)
    public var allocatedSize: UInt64  // on-disk bytes (ATTR_FILE_ALLOCSIZE)
    public var modifiedDate: UInt32   // seconds since epoch, clamped to UInt32
    public var inode: UInt64          // file ID for firmlink deduplication
    public var device: Int32          // device ID for firmlink deduplication

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool,
        fileSize: UInt64,
        allocatedSize: UInt64,
        modifiedDate: UInt32,
        inode: UInt64,
        device: Int32
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.fileSize = fileSize
        self.allocatedSize = allocatedSize
        self.modifiedDate = modifiedDate
        self.inode = inode
        self.device = device
    }
}

// MARK: - FilesystemProvider Protocol

/// Abstracts all filesystem I/O so FileScanner can be tested without touching disk.
///
/// The high-level interface (`listDirectory`, `deviceID`) was chosen over a 1:1
/// getattrlistbulk shim because the raw binary format (packed structs, variable-length
/// name fields, pointer arithmetic) is extremely difficult to reproduce faithfully in a
/// mock. A `[DirectoryEntry]`-based API is equally testable and far less fragile.
public protocol FilesystemProvider: Sendable {
    /// List the immediate children of `path`.
    /// Returns `nil` if the directory cannot be opened (e.g., permission denied).
    /// Returns an empty array for a directory that is accessible but empty.
    func listDirectory(path: String) -> [DirectoryEntry]?

    /// Recursively compute total logical and allocated size for an opaque bundle directory.
    /// FileScanner delegates bundle-size computation here so implementations can use
    /// whatever syscall they prefer.
    func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64)

    /// Return the (dev, inode) pair for `path`, or nil on failure.
    /// Used by FileScanner to seed the visited-directory set for the scan root.
    func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)?

    /// Return volume statistics for `path`, used for inode-count estimation and
    /// network-FS detection. Returns nil on failure.
    func volumeStats(forPath path: String) -> StatfsResult?
}

/// Subset of statfs fields consumed by FileScanner.
public struct StatfsResult: Sendable {
    public var totalFiles: UInt64     // f_files
    public var freeFiles: UInt64      // f_ffree
    public var filesystemType: String // f_fstypename
    public init(totalFiles: UInt64, freeFiles: UInt64, filesystemType: String) {
        self.totalFiles = totalFiles
        self.freeFiles = freeFiles
        self.filesystemType = filesystemType
    }
}

// MARK: - RealFilesystemProvider

/// Production implementation: forwards to actual Darwin syscalls.
public struct RealFilesystemProvider: FilesystemProvider {

    public init() {}

    public func listDirectory(path: String) -> [DirectoryEntry]? {
        // Open directory — O_NOFOLLOW prevents following symlinks at the directory itself
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }  // nil signals open failure (permission denied, etc.)
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = kRequestedCommonAttrs
        attrList.fileattr = kRequestedFileAttrs

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [DirectoryEntry] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count <= 0 { break }

            let bufferEnd = buffer.advanced(by: bufferSize)
            var entryPtr = buffer
            for _ in 0..<count {
                guard entryPtr.advanced(by: MemoryLayout<UInt32>.size) <= bufferEnd else { break }
                let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                guard entryLength > 0, entryLength >= kOffsetFileData else { break }

                let entry = entryPtr

                let entryName = parseEntryName(from: entry, entryLength: entryLength)
                guard !entryName.isEmpty, entryName != ".", entryName != ".." else {
                    entryPtr = entryPtr.advanced(by: entryLength)
                    continue
                }

                let devID   = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)
                let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                let isDir     = objType == VDIR.rawValue
                let isSymlink = objType == VLNK.rawValue
                let modSec  = entry.advanced(by: kOffsetModTime).loadUnaligned(as: Int.self)
                let modDate = UInt32(clamping: max(0, modSec))
                let fileID  = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)

                var dataLength: UInt64 = 0
                var allocSize: UInt64 = 0
                if !isDir && !isSymlink {
                    guard entryLength >= kOffsetFileData + 2 * MemoryLayout<off_t>.size else { break }
                    (dataLength, allocSize) = parseFileSizes(from: entry)
                }

                entries.append(DirectoryEntry(
                    name: entryName,
                    isDirectory: isDir,
                    isSymlink: isSymlink,
                    fileSize: dataLength,
                    allocatedSize: allocSize,
                    modifiedDate: modDate,
                    inode: fileID,
                    device: devID
                ))

                let next = entryPtr.advanced(by: entryLength)
                guard next <= bufferEnd else { break }
                entryPtr = next
            }
        }

        return entries
    }

    public func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64) {
        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var stack: [String] = [path]
        var seen = Set<InodeKeyPublic>()

        var rootStat = Darwin.stat()
        guard lstat(path, &rootStat) == 0 else {
            return (fileSize: 0, allocatedSize: 0)
        }
        seen.insert(InodeKeyPublic(dev: rootStat.st_dev, inode: rootStat.st_ino))

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while let currentDir = stack.popLast(), !isCancelled() {
            let fd = open(currentDir, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var attrList = attrlist()
            attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrList.commonattr = kRequestedCommonAttrs
            attrList.fileattr = kRequestedFileAttrs

            while !isCancelled() {
                let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
                if count <= 0 { break }
                let bufferEnd = buffer.advanced(by: bufferSize)
                var entryPtr = buffer
                for _ in 0..<count {
                    guard !isCancelled() else { break }
                    guard entryPtr.advanced(by: MemoryLayout<UInt32>.size) <= bufferEnd else { break }
                    let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                    guard entryLength > 0, entryLength >= kOffsetFileData else { break }
                    let entry = entryPtr
                    let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                    let isDir     = objType == VDIR.rawValue
                    let isSymlink = objType == VLNK.rawValue

                    let next = entryPtr.advanced(by: entryLength)
                    guard next <= bufferEnd else { break }

                    guard !isSymlink else {
                        entryPtr = next
                        continue
                    }

                    if isDir {
                        let entryName = parseEntryName(from: entry, entryLength: entryLength)
                        if !entryName.isEmpty, entryName != ".", entryName != ".." {
                            let devID  = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)
                            let fileID = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)
                            if seen.insert(InodeKeyPublic(dev: devID, inode: fileID)).inserted {
                                stack.append(currentDir + "/" + entryName)
                            }
                        }
                    } else {
                        guard entryLength >= kOffsetFileData + 2 * MemoryLayout<off_t>.size else {
                            entryPtr = next
                            continue
                        }
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

    public func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)? {
        var s = Darwin.stat()
        guard lstat(path, &s) == 0 else { return nil }
        return (s.st_dev, s.st_ino)
    }

    public func volumeStats(forPath path: String) -> StatfsResult? {
        return callStatfs(path: path)
    }
}

// MARK: - Shared inode key (used by RealFilesystemProvider.computeBundleSize)

/// Hashable (dev, inode) pair — avoids XOR collision risk.
struct InodeKeyPublic: Hashable {
    let dev: Int32
    let inode: UInt64
}

// MARK: - Attribute layout constants (shared between provider and old parsing helpers)

// These constants mirror the ones in FileScanner.swift so RealFilesystemProvider
// can access them without code duplication. (They live in the same module.)
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

private let kOffsetName:     Int = 24
private let kOffsetDevID:    Int = 32
private let kOffsetObjType:  Int = 36
private let kOffsetModTime:  Int = 40
private let kOffsetFileID:   Int = 56
private let kOffsetFileData: Int = 64

private func parseEntryName(from entry: UnsafeRawPointer, entryLength: Int) -> String {
    let nameRef = entry.advanced(by: kOffsetName)
    let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
    let nameLength = Int(nameRef.advanced(by: 4).loadUnaligned(as: UInt32.self))
    // Validate that the name bytes lie entirely within the declared entry boundary.
    guard nameLength > 1,
          kOffsetName + nameOffset >= 0,
          kOffsetName + nameOffset + nameLength <= entryLength else { return "" }
    let namePtr = nameRef.advanced(by: nameOffset)
    let data = Data(bytes: namePtr, count: nameLength - 1)
    return String(data: data, encoding: .utf8) ?? ""
}

private func parseFileSizes(from entry: UnsafeRawPointer) -> (dataLength: UInt64, allocSize: UInt64) {
    let allocSize  = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData).loadUnaligned(as: off_t.self)))
    let dataLength = UInt64(bitPattern: Int64(entry.advanced(by: kOffsetFileData + 8).loadUnaligned(as: off_t.self)))
    return (dataLength, allocSize)
}

/// Free helper to call the C statfs(2) syscall without naming ambiguity.
/// Inside a struct/class method named `volumeStats`, `Darwin.statfs` can be
/// ambiguous between the struct type and the function. A top-level free function
/// avoids that by having no local symbol called `statfs`.
private func callStatfs(path: String) -> StatfsResult? {
    var s = statfs()  // Darwin.statfs struct, unambiguous here
    guard statfs(path, &s) == 0 else { return nil }
    let name: String = withUnsafePointer(to: s.f_fstypename) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    return StatfsResult(
        totalFiles: s.f_files,
        freeFiles: s.f_ffree,
        filesystemType: name
    )
}

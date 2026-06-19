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

// MARK: - Raw Directory Entry

/// Non-owning entry view backed by the current getattrlistbulk buffer.
/// The `nameBytes` pointer is valid only for the duration of the callback that receives it.
public struct RawDirectoryEntry {
    public var nameBytes: UnsafeBufferPointer<UInt8>
    public var isDirectory: Bool
    public var fileSize: UInt64
    public var allocatedSize: UInt64
    public var modifiedDate: UInt32
    public var inode: UInt64
    public var device: Int32
}

// MARK: - FilesystemProvider Protocol

/// Abstracts all filesystem I/O so FileScanner can be tested without touching disk.
///
/// The high-level interface (`listDirectory`, `forEachDirectoryEntry`, `deviceID`) was chosen over a 1:1
/// getattrlistbulk shim because the raw binary format (packed structs, variable-length
/// name fields, pointer arithmetic) is extremely difficult to reproduce faithfully in a
/// mock. A `[DirectoryEntry]`-based API is equally testable and far less fragile.
public protocol FilesystemProvider: Sendable {
    /// List the immediate children of `path`.
    /// Returns `nil` if the directory cannot be opened (e.g., permission denied).
    /// Returns an empty array for a directory that is accessible but empty.
    func listDirectory(path: String) -> [DirectoryEntry]?

    /// Visit immediate children of `path` without requiring the provider to materialize
    /// an intermediate array. Returns false if the directory cannot be opened.
    func forEachDirectoryEntry(path: String, _ body: (DirectoryEntry) -> Bool) -> Bool

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

public extension FilesystemProvider {
    func forEachDirectoryEntry(path: String, _ body: (DirectoryEntry) -> Bool) -> Bool {
        guard let entries = listDirectory(path: path) else { return false }
        for entry in entries {
            if !body(entry) { break }
        }
        return true
    }
}

/// Subset of statfs fields consumed by FileScanner.
public struct StatfsResult: Sendable {
    public var totalFiles: UInt64     // f_files
    public var freeFiles: UInt64      // f_ffree
    public var filesystemType: String // f_fstypename
    public var mountPoint: String     // f_mntonname
    public init(
        totalFiles: UInt64,
        freeFiles: UInt64,
        filesystemType: String,
        mountPoint: String = "/"
    ) {
        self.totalFiles = totalFiles
        self.freeFiles = freeFiles
        self.filesystemType = filesystemType
        self.mountPoint = mountPoint
    }
}

// MARK: - RealFilesystemProvider

/// Production implementation: forwards to actual Darwin syscalls.
public struct RealFilesystemProvider: FilesystemProvider {
    public static let directoryBufferSize: Int = {
        let configured = ProcessInfo.processInfo.environment["DIRWIZ_BULK_BUFFER_BYTES"].flatMap(Int.init)
        return max(16 * 1024, configured ?? 256 * 1024)
    }()

    public init() {}

    public func listDirectory(path: String) -> [DirectoryEntry]? {
        var entries: [DirectoryEntry] = []
        guard forEachRawDirectoryEntry(path: path, { entry in
            let name = String(decoding: entry.nameBytes, as: UTF8.self)
            entries.append(DirectoryEntry(
                name: name,
                isDirectory: entry.isDirectory,
                isSymlink: false,
                fileSize: entry.fileSize,
                allocatedSize: entry.allocatedSize,
                modifiedDate: entry.modifiedDate,
                inode: entry.inode,
                device: entry.device
            ))
            return true
        }) else { return nil }
        return entries
    }

    public func forEachDirectoryEntry(path: String, _ body: (DirectoryEntry) -> Bool) -> Bool {
        forEachRawDirectoryEntry(path: path) { entry in
            let name = String(decoding: entry.nameBytes, as: UTF8.self)
            return body(DirectoryEntry(
                name: name,
                isDirectory: entry.isDirectory,
                isSymlink: false,
                fileSize: entry.fileSize,
                allocatedSize: entry.allocatedSize,
                modifiedDate: entry.modifiedDate,
                inode: entry.inode,
                device: entry.device
            ))
        }
    }

    public func forEachRawDirectoryEntry(path: String, _ body: (RawDirectoryEntry) -> Bool) -> Bool {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.directoryBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        return forEachRawDirectoryEntry(
            path: path,
            buffer: buffer,
            bufferSize: Self.directoryBufferSize,
            body
        )
    }

    public func forEachRawDirectoryEntry(
        path: String,
        buffer: UnsafeMutableRawPointer,
        bufferSize: Int,
        _ body: (RawDirectoryEntry) -> Bool
    ) -> Bool {
        // Open directory — O_NOFOLLOW prevents following symlinks at the directory itself
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }  // false signals open failure (permission denied, etc.)
        defer { close(fd) }
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = kRequestedCommonAttrs
        attrList.fileattr = kRequestedFileAttrs

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
                let objType = entry.advanced(by: kOffsetObjType).loadUnaligned(as: UInt32.self)
                let isDir     = objType == VDIR.rawValue
                let isSymlink = objType == VLNK.rawValue
                let next = entryPtr.advanced(by: entryLength)
                guard next <= bufferEnd else { break }

                guard !isSymlink else {
                    entryPtr = next
                    continue
                }

                guard let entryName = parseEntryNameBytes(from: entry, entryLength: entryLength),
                      !isDotOrDotDot(entryName) else {
                    entryPtr = next
                    continue
                }

                let devID   = entry.advanced(by: kOffsetDevID).loadUnaligned(as: Int32.self)
                let modSec  = entry.advanced(by: kOffsetModTime).loadUnaligned(as: Int.self)
                let modDate = UInt32(clamping: max(0, modSec))
                let fileID  = entry.advanced(by: kOffsetFileID).loadUnaligned(as: UInt64.self)

                var dataLength: UInt64 = 0
                var allocSize: UInt64 = 0
                if !isDir {
                    guard entryLength >= kOffsetFileData + 2 * MemoryLayout<off_t>.size else { break }
                    (dataLength, allocSize) = parseFileSizes(from: entry)
                }

                let shouldContinue = body(RawDirectoryEntry(
                    nameBytes: entryName,
                    isDirectory: isDir,
                    fileSize: dataLength,
                    allocatedSize: allocSize,
                    modifiedDate: modDate,
                    inode: fileID,
                    device: devID
                ))
                guard shouldContinue else { return true }

                entryPtr = next
            }
        }

        return true
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

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while let currentDir = stack.popLast(), !isCancelled() {
            let fd = open(currentDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }

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
                                stack.append(appendPathComponent(currentDir, entryName))
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
            close(fd)
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
    guard let nameBytes = parseEntryNameBytes(from: entry, entryLength: entryLength) else {
        return ""
    }
    return nameBytes.baseAddress.map { pointer in
        String(validatingUTF8: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)) ?? ""
    } ?? ""
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

private func parseEntryNameBytes(from entry: UnsafeRawPointer, entryLength: Int) -> UnsafeBufferPointer<UInt8>? {
    let nameRef = entry.advanced(by: kOffsetName)
    let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
    let nameLength = Int(nameRef.advanced(by: 4).loadUnaligned(as: UInt32.self))
    // Validate that the name bytes lie entirely within the declared entry boundary.
    guard nameLength > 1,
          kOffsetName + nameOffset >= 0,
          kOffsetName + nameOffset + nameLength <= entryLength else { return nil }
    let namePtr = nameRef.advanced(by: nameOffset)
    guard namePtr.advanced(by: nameLength - 1).load(as: UInt8.self) == 0 else { return nil }
    return UnsafeBufferPointer(
        start: namePtr.assumingMemoryBound(to: UInt8.self),
        count: nameLength - 1
    )
}

private func isDotOrDotDot(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    if bytes.count == 1 {
        return bytes[0] == UInt8(ascii: ".")
    }
    if bytes.count == 2 {
        return bytes[0] == UInt8(ascii: ".") && bytes[1] == UInt8(ascii: ".")
    }
    return false
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
    let mountPoint: String = withUnsafePointer(to: s.f_mntonname) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return StatfsResult(
        totalFiles: s.f_files,
        freeFiles: s.f_ffree,
        filesystemType: name,
        mountPoint: mountPoint
    )
}

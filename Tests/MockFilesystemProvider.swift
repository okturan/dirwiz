import Foundation
@testable import DirWizCore
@testable import DirWizUI

// MARK: - MockFilesystemProvider

/// In-memory filesystem provider for testing FileScanner without disk I/O.
///
/// `@unchecked Sendable` is safe here because all configuration is done
/// before the mock is passed to FileScanner (single-threaded setup phase).
/// During scanning the mock is read-only (FileScanner never mutates it).
///
/// Usage:
///   var mock = MockFilesystemProvider()
///   mock.directories["/root"] = [
///       MockFilesystemProvider.file(name: "hello.txt", size: 1024),
///       MockFilesystemProvider.dir(name: "subdir"),
///   ]
///   mock.directories["/root/subdir"] = []
final class MockFilesystemProvider: @unchecked Sendable, FilesystemProvider {

    // MARK: - Entry Builder

    /// Convenience constructor for directory entries.
    static func dir(
        name: String,
        inode: UInt64 = 0,
        device: Int32 = 1,
        modifiedDate: UInt32 = 0
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            isDirectory: true,
            isSymlink: false,
            fileSize: 0,
            allocatedSize: 0,
            modifiedDate: modifiedDate,
            inode: inode,
            device: device
        )
    }

    /// Convenience constructor for regular-file entries.
    static func file(
        name: String,
        size: UInt64,
        allocatedSize: UInt64? = nil,
        inode: UInt64 = 0,
        device: Int32 = 1,
        modifiedDate: UInt32 = 0
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            isDirectory: false,
            isSymlink: false,
            fileSize: size,
            allocatedSize: allocatedSize ?? size,
            modifiedDate: modifiedDate,
            inode: inode,
            device: device
        )
    }

    /// Convenience constructor for symlink entries.
    static func symlink(name: String, inode: UInt64 = 0, device: Int32 = 1) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            isDirectory: false,
            isSymlink: true,
            fileSize: 0,
            allocatedSize: 0,
            modifiedDate: 0,
            inode: inode,
            device: device
        )
    }

    // MARK: - Configuration

    /// Map from absolute directory path → its children.
    /// A path mapped to `nil` means the directory cannot be opened (permission denied).
    /// A path mapped to `[]` means the directory is accessible but empty.
    /// A path not present in the map returns `[]` (treated as an accessible empty directory).
    var directories: [String: [DirectoryEntry]] = [:]

    /// Device+inode info for paths (used for the scan-root visited-set seeding).
    var inodeMap: [String: (device: Int32, inode: UInt64)] = [:]

    /// Volume stats returned for the scan root path. Default simulates a small local FS.
    var mockVolumeStats: StatfsResult? = StatfsResult(
        totalFiles: 10_000,
        freeFiles: 5_000,
        filesystemType: "apfs",
        mountPoint: "/"
    )

    // MARK: - FilesystemProvider

    func listDirectory(path: String) -> [DirectoryEntry]? {
        // If the path is explicitly keyed with nil, simulate open failure.
        if let entries = directories[path] {
            return entries
        }
        // Unmapped paths: return empty (no failure, just nothing there).
        return []
    }

    func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64) {
        // Recursively sum all files in the mock tree rooted at `path`.
        var totalFile: UInt64 = 0
        var totalAlloc: UInt64 = 0
        var stack: [String] = [path]

        while let current = stack.popLast() {
            guard !isCancelled() else { break }
            let children = directories[current] ?? []
            for child in children {
                guard !isCancelled() else { break }
                if child.isDirectory {
                    stack.append(current + "/" + child.name)
                } else if !child.isSymlink {
                    totalFile  += child.fileSize
                    totalAlloc += child.allocatedSize
                }
            }
        }
        return (totalFile, totalAlloc)
    }

    func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)? {
        return inodeMap[path]
    }

    func volumeStats(forPath path: String) -> StatfsResult? {
        return mockVolumeStats
    }
}

// MARK: - FailingMockFilesystemProvider

/// Extension of MockFilesystemProvider that can simulate open() failures on specific paths.
/// `@unchecked Sendable`: configured before passing to FileScanner; read-only during scanning.
final class FailingMockFilesystemProvider: @unchecked Sendable, FilesystemProvider {
    var inner = MockFilesystemProvider()
    /// Paths that should return nil (permission denied).
    var failingPaths: Set<String> = []

    func listDirectory(path: String) -> [DirectoryEntry]? {
        if failingPaths.contains(path) { return nil }
        return inner.listDirectory(path: path)
    }

    func computeBundleSize(path: String, isCancelled: () -> Bool) -> (fileSize: UInt64, allocatedSize: UInt64) {
        inner.computeBundleSize(path: path, isCancelled: isCancelled)
    }

    func deviceAndInode(forPath path: String) -> (device: Int32, inode: UInt64)? {
        inner.deviceAndInode(forPath: path)
    }

    func volumeStats(forPath path: String) -> StatfsResult? {
        inner.volumeStats(forPath: path)
    }
}

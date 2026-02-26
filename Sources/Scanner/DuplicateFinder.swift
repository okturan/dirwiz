import Foundation
import CommonCrypto
import os

// MARK: - DuplicateFinder

/// Two-pass duplicate file detection engine.
///
/// Pass 1: Group files by size. Unique sizes cannot be duplicates (eliminates ~80%).
/// Pass 2: For size-matched groups, read first 4KB + last 4KB, hash them. Eliminate non-matches.
/// Pass 3: For remaining candidates, compute full-file hash. Confirmed duplicates share a hash.
public final class DuplicateFinder {

    /// Minimum file size to consider. Files under this threshold are skipped.
    private let minimumFileSize: UInt64 = 1

    /// Bytes to read from head and tail for partial hashing.
    private let partialReadSize = 4096

    public init() {}

    // MARK: - Public API

    /// Find duplicate files in the given FileTree.
    ///
    /// - Parameters:
    ///   - tree: The scanned file tree.
    ///   - progress: Optional callback with (filesProcessed, totalCandidates).
    /// - Returns: Array of DuplicateGroup sorted by wastedSpace descending.
    public func findDuplicates(
        in tree: FileTree,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> [DuplicateGroup] {

        // ---------------------------------------------------------------
        // Pass 1: Group files by size
        // ---------------------------------------------------------------
        let snapshot = tree.nodesSnapshot()
        var sizeGroups: [UInt64: [UInt32]] = [:]
        sizeGroups.reserveCapacity(snapshot.count / 2)

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory, node.fileSize >= minimumFileSize else { continue }
            sizeGroups[node.fileSize, default: []].append(UInt32(i))
        }

        // Remove unique sizes (can't be duplicates)
        sizeGroups = sizeGroups.filter { $0.value.count >= 2 }

        // Flatten candidates for progress reporting
        let candidateGroups = Array(sizeGroups.values)
        let totalCandidates = candidateGroups.reduce(0) { $0 + $1.count }

        if totalCandidates == 0 {
            return []
        }

        // ---------------------------------------------------------------
        // Pass 2: Partial hash (first 4KB + last 4KB)
        // ---------------------------------------------------------------
        let processedCount = OSAllocatedUnfairLock(initialState: 0)

        // Collect partial-hash groups using TaskGroup for concurrency
        let partialGroups: [FileHashKey: [UInt32]] = await withTaskGroup(
            of: [(FileHashKey, UInt32)].self,
            returning: [FileHashKey: [UInt32]].self
        ) { group in
            // Process each size group in parallel
            for sizeGroup in candidateGroups {
                let fileSize = snapshot[Int(sizeGroup[0])].fileSize
                group.addTask {
                    var results: [(FileHashKey, UInt32)] = []
                    for nodeIndex in sizeGroup {
                        let path = tree.path(at: nodeIndex)
                        if let hash = self.partialHash(path: path, fileSize: fileSize) {
                            let key = FileHashKey(size: fileSize, hash: hash)
                            results.append((key, nodeIndex))
                        }
                        // Update progress
                        let current = processedCount.withLock { state -> Int in
                            state += 1
                            return state
                        }
                        if current % 500 == 0 {
                            progress?(current, totalCandidates)
                        }
                    }
                    return results
                }
            }

            // Collect results
            var collected: [FileHashKey: [UInt32]] = [:]
            for await batch in group {
                for (key, nodeIndex) in batch {
                    collected[key, default: []].append(nodeIndex)
                }
            }
            return collected
        }

        // Remove groups with only one member (partial hash unique)
        let partialMatches = partialGroups.filter { $0.value.count >= 2 }

        if partialMatches.isEmpty {
            progress?(totalCandidates, totalCandidates)
            return []
        }

        // ---------------------------------------------------------------
        // Pass 3: Full-file hash for remaining candidates
        // ---------------------------------------------------------------
        let fullGroups: [FileHashKey: [UInt32]] = await withTaskGroup(
            of: [(FileHashKey, UInt32)].self,
            returning: [FileHashKey: [UInt32]].self
        ) { group in
            for (partialKey, indices) in partialMatches {
                group.addTask {
                    var results: [(FileHashKey, UInt32)] = []
                    for nodeIndex in indices {
                        let path = tree.path(at: nodeIndex)
                        if let hash = self.fullFileHash(path: path) {
                            let key = FileHashKey(size: partialKey.size, hash: hash)
                            results.append((key, nodeIndex))
                        }
                    }
                    return results
                }
            }

            var collected: [FileHashKey: [UInt32]] = [:]
            for await batch in group {
                for (key, nodeIndex) in batch {
                    collected[key, default: []].append(nodeIndex)
                }
            }
            return collected
        }

        // Build DuplicateGroup results from confirmed duplicates
        var results: [DuplicateGroup] = []
        for (key, indices) in fullGroups {
            guard indices.count >= 2 else { continue }
            let paths = indices.map { tree.path(at: $0) }
            let dupGroup = DuplicateGroup(
                fileSize: key.size,
                hash: key.hash,
                paths: paths
            )
            results.append(dupGroup)
        }

        // Sort by wasted space descending
        results.sort { $0.wastedSpace > $1.wastedSpace }

        progress?(totalCandidates, totalCandidates)
        return results
    }

    // MARK: - Hashing

    /// FNV-1a 64-bit hash.
    private func fnv1a(_ data: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    /// Read first 4KB + last 4KB and compute a combined hash.
    /// For files <= 8KB, reads the entire file.
    private func partialHash(path: String, fileSize: UInt64) -> UInt64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let readSize = partialReadSize
        let totalRead = fileSize <= UInt64(readSize * 2)
            ? Int(fileSize)
            : readSize * 2

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: totalRead, alignment: 8)
        defer { buffer.deallocate() }

        if fileSize <= UInt64(readSize * 2) {
            // Read entire small file
            let bytesRead = read(fd, buffer, totalRead)
            guard bytesRead == totalRead else { return nil }
        } else {
            // Read first 4KB
            let headRead = read(fd, buffer, readSize)
            guard headRead == readSize else { return nil }

            // Seek to last 4KB
            let seekPos = off_t(fileSize) - off_t(readSize)
            guard lseek(fd, seekPos, SEEK_SET) == seekPos else { return nil }

            let tailRead = read(fd, buffer.advanced(by: readSize), readSize)
            guard tailRead == readSize else { return nil }
        }

        let rawBuffer = UnsafeRawBufferPointer(start: buffer, count: totalRead)
        return fnv1a(rawBuffer)
    }

    /// Compute full-file SHA-256 hash and fold it down to 64 bits.
    private func fullFileHash(path: String) -> UInt64? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else { return nil }
        let byteCount = Int(fileInfo.st_size)

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        if byteCount == 0 {
            _ = CC_SHA256(nil, 0, &digest)
            return digestToUInt64(digest)
        }

        let mapped = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fd, 0)
        guard mapped != MAP_FAILED, let mapped else { return nil }
        defer { munmap(mapped, byteCount) }

        _ = CC_SHA256(mapped, CC_LONG(byteCount), &digest)
        return digestToUInt64(digest)
    }

    private func digestToUInt64(_ digest: [UInt8]) -> UInt64 {
        precondition(digest.count >= 8)
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

// MARK: - Internal Key Type

private struct FileHashKey: Hashable {
    let size: UInt64
    let hash: UInt64
}

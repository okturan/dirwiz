import Foundation
import CryptoKit
import Synchronization

// MARK: - DuplicateFinder

/// Two-pass duplicate file detection engine.
///
/// Pass 1: Group files by size. Unique sizes cannot be duplicates (eliminates ~80%).
/// Pass 2: For size-matched groups, read first 4KB + last 4KB, hash them. Eliminate non-matches.
/// Pass 3: For remaining candidates, compute full-file hash. Confirmed duplicates share a hash.
public final class DuplicateFinder {

    /// Minimum file size to consider. Files under this threshold are skipped.
    /// Set to 1 to exclude zero-byte files (e.g., .gitkeep, .DS_Store stubs) —
    /// they are technically "duplicates" of each other but not useful to report.
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
        let processedCount = Mutex(0)

        // Collect partial-hash groups using TaskGroup for concurrency
        let partialGroups: [PartialHashKey: [UInt32]] = await withTaskGroup(
            of: [(PartialHashKey, UInt32)].self,
            returning: [PartialHashKey: [UInt32]].self
        ) { group in
            // Process each size group in parallel
            for sizeGroup in candidateGroups {
                let fileSize = snapshot[Int(sizeGroup[0])].fileSize
                group.addTask {
                    var results: [(PartialHashKey, UInt32)] = []
                    for nodeIndex in sizeGroup {
                        let hash = tree.withCPath(at: nodeIndex) { cPath in
                            self.partialHash(cPath: cPath, fileSize: fileSize)
                        }
                        if let hash {
                            let key = PartialHashKey(size: fileSize, hash: hash)
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
            var collected: [PartialHashKey: [UInt32]] = [:]
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
        let fullGroups: [FullHashKey: [UInt32]] = await withTaskGroup(
            of: [(FullHashKey, UInt32)].self,
            returning: [FullHashKey: [UInt32]].self
        ) { group in
            for (partialKey, indices) in partialMatches {
                group.addTask {
                    var results: [(FullHashKey, UInt32)] = []
                    for nodeIndex in indices {
                        let digest = tree.withCPath(at: nodeIndex) { cPath in
                            self.fullFileHash(cPath: cPath)
                        }
                        if let digest {
                            let key = FullHashKey(size: partialKey.size, lo: digest.lo, hi: digest.hi)
                            results.append((key, nodeIndex))
                        }
                    }
                    return results
                }
            }

            var collected: [FullHashKey: [UInt32]] = [:]
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
                hash: key.lo,  // Lower 64 bits for display identity
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
    private func partialHash(cPath: UnsafePointer<CChar>, fileSize: UInt64) -> UInt64? {
        // Zero-byte files all share the same partial hash.
        if fileSize == 0 { return 0 }

        let fd = open(cPath, O_RDONLY)
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

    /// Compute full-file SHA-256 hash using streaming read(), returning 128-bit digest prefix.
    /// Uses read() instead of mmap to avoid SIGBUS if another process truncates
    /// the file while we're hashing it (mmap would crash the entire app).
    /// Returns 128 bits (two UInt64s) instead of 64 to minimize collision risk.
    private func fullFileHash(cPath: UnsafePointer<CChar>) -> (lo: UInt64, hi: UInt64)? {
        let fd = open(cPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else { return nil }
        let byteCount = Int(fileInfo.st_size)

        // Zero-byte files are valid duplicates of each other.
        if byteCount == 0 { return (0, 0) }

        let chunkSize = 128 * 1024  // 128 KB read chunks
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 8)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            let bytesRead = read(fd, buffer, toRead)
            // Error or unexpected EOF (file truncated by another process).
            guard bytesRead > 0 else { return nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            remaining -= bytesRead
        }

        let digest = hasher.finalize()
        return digest.withUnsafeBytes { buf in
            (lo: buf.loadUnaligned(as: UInt64.self),
             hi: buf.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
    }
}

// MARK: - Internal Key Type

/// Pass 2 key: (size, FNV-1a partial hash). UInt64 is fine as a pre-filter.
private struct PartialHashKey: Hashable {
    let size: UInt64
    let hash: UInt64
}

/// Pass 3 key: (size, 128-bit SHA256 prefix). Using 128 bits instead of 64
/// reduces collision probability from 2^-64 to 2^-128 for the same cost.
private struct FullHashKey: Hashable {
    let size: UInt64
    let lo: UInt64
    let hi: UInt64
}

import Foundation
import Synchronization

// MARK: - StreamingHash128

/// Fast non-cryptographic 128-bit streaming hash for duplicate file detection.
///
/// Uses two independent FNV-1a-inspired lanes with different seeds and
/// multipliers so the two 64-bit halves are decorrelated. Processing is done
/// in 8-byte (UInt64) word-sized chunks for speed, with a byte-at-a-time tail
/// handler for the remaining bytes.
///
/// This is intentionally NOT a cryptographic hash — it trades collision
/// resistance below 2^-64 for throughput, which is appropriate here because:
///  - Files are pre-grouped by exact byte-size before hashing.
///  - A partial-hash pass (FNV-1a on head+tail) eliminates most non-duplicates.
///  - The full-file hash is the final confirmation step; accidental collisions
///    are astronomically unlikely and never produce data loss (only a false
///    "duplicate" report that the user can dismiss).
private struct StreamingHash128 {
    // Lane 0: classic FNV-1a 64-bit seed and prime.
    private var lo: UInt64 = 0xcbf29ce484222325
    // Lane 1: different seed (golden-ratio constant) and a distinct prime so
    // the two lanes are statistically independent.
    private var hi: UInt64 = 0x9e3779b97f4a7c15

    private static let mulLo: UInt64 = 0x100000001b3          // FNV prime
    private static let mulHi: UInt64 = 0x517cc1b727220a95     // distinct prime

    /// Incorporate a chunk of bytes into the hash state.
    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var offset = 0
        let count  = buffer.count

        // Fast path: consume 8 bytes at a time.
        while offset + 8 <= count {
            let word = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            lo ^= word
            lo &*= StreamingHash128.mulLo
            hi ^= word.byteSwapped   // feed the same word rotated so lanes diverge
            hi &*= StreamingHash128.mulHi
            offset += 8
        }

        // Slow path: consume remaining bytes one at a time.
        while offset < count {
            let byte = UInt64(buffer[offset])
            lo ^= byte
            lo &*= StreamingHash128.mulLo
            hi ^= byte &<< 32        // place byte in upper half to separate lanes
            hi &*= StreamingHash128.mulHi
            offset += 1
        }
    }

    /// Return the final 128-bit digest as two UInt64 values.
    func finalize() -> (lo: UInt64, hi: UInt64) {
        // Avalanche both lanes so short, similar inputs don't map to nearby outputs.
        var a = lo
        a ^= a &>> 33
        a &*= 0xff51afd7ed558ccd
        a ^= a &>> 33
        a &*= 0xc4ceb9fe1a85ec53
        a ^= a &>> 33

        var b = hi
        b ^= b &>> 33
        b &*= 0xc4ceb9fe1a85ec53   // swap constants vs lane 0
        b ^= b &>> 33
        b &*= 0xff51afd7ed558ccd
        b ^= b &>> 33

        return (lo: a, hi: b)
    }
}

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
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
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
        let readSize = partialReadSize

        // Collect partial-hash groups using TaskGroup for concurrency.
        // Batch small size groups into chunks to avoid spawning one task per group
        // (e.g., 50K groups of 2 files each → 50K tasks). Each task opens files
        // sequentially, so the concurrent FD count is bounded by the cooperative
        // thread pool size (~CPU count), well within OPEN_MAX.
        let maxGroupsPerTask = 64
        typealias PartialBatch = (matches: [(PartialHashKey, UInt32)], processed: Int)
        let partialGroups: [PartialHashKey: [UInt32]] = await withTaskGroup(
            of: PartialBatch.self,
            returning: [PartialHashKey: [UInt32]].self
        ) { group in
            // Batch size groups into chunks to reduce task overhead
            for chunkStart in stride(from: 0, to: candidateGroups.count, by: maxGroupsPerTask) {
                let chunkEnd = min(chunkStart + maxGroupsPerTask, candidateGroups.count)
                let chunk = candidateGroups[chunkStart..<chunkEnd]
                group.addTask {
                    var results: [(PartialHashKey, UInt32)] = []
                    var processed = 0
                    for sizeGroup in chunk {
                        guard !Task.isCancelled else { break }
                        let fileSize = snapshot[Int(sizeGroup[0])].fileSize
                        for nodeIndex in sizeGroup {
                            guard !Task.isCancelled else { break }
                            let hash = tree.withCPath(at: nodeIndex) { cPath in
                                Self.partialHash(cPath: cPath, fileSize: fileSize, readSize: readSize)
                            }
                            if let hash {
                                let key = PartialHashKey(size: fileSize, hash: hash)
                                results.append((key, nodeIndex))
                            }
                            processed += 1
                        }
                    }
                    return (results, processed)
                }
            }

            // Collect results
            var collected: [PartialHashKey: [UInt32]] = [:]
            var processedTotal = 0
            var lastProgressTime = CFAbsoluteTimeGetCurrent()
            for await batch in group {
                processedTotal += batch.processed
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgressTime >= 0.2 || processedTotal == totalCandidates {
                    lastProgressTime = now
                    await progress?(processedTotal, totalCandidates)
                }
                for (key, nodeIndex) in batch.matches {
                    collected[key, default: []].append(nodeIndex)
                }
            }
            return collected
        }

        // Remove groups with only one member (partial hash unique)
        let partialMatches = partialGroups.filter { $0.value.count >= 2 }

        if partialMatches.isEmpty {
            await progress?(totalCandidates, totalCandidates)
            return []
        }

        // ---------------------------------------------------------------
        // Pass 3: Full-file hash for remaining candidates
        // ---------------------------------------------------------------
        let partialMatchArray = Array(partialMatches)
        let fullGroups: [FullHashKey: [UInt32]] = await withTaskGroup(
            of: [(FullHashKey, UInt32)].self,
            returning: [FullHashKey: [UInt32]].self
        ) { group in
            for chunkStart in stride(from: 0, to: partialMatchArray.count, by: maxGroupsPerTask) {
                let chunkEnd = min(chunkStart + maxGroupsPerTask, partialMatchArray.count)
                let chunk = partialMatchArray[chunkStart..<chunkEnd]
                group.addTask {
                    var results: [(FullHashKey, UInt32)] = []
                    for (partialKey, indices) in chunk {
                        guard !Task.isCancelled else { break }
                        for nodeIndex in indices {
                            guard !Task.isCancelled else { break }
                            let digest = tree.withCPath(at: nodeIndex) { cPath in
                                Self.fullFileHash(cPath: cPath)
                            }
                            if let digest {
                                let key = FullHashKey(size: partialKey.size, lo: digest.lo, hi: digest.hi)
                                results.append((key, nodeIndex))
                            }
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

        await progress?(totalCandidates, totalCandidates)
        return results
    }

    // MARK: - Hashing

    /// FNV-1a 64-bit hash.
    private static func fnv1a(_ data: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    /// Read first 4KB + last 4KB and compute a combined hash.
    /// For files <= 8KB, reads the entire file.
    private static func partialHash(cPath: UnsafePointer<CChar>, fileSize: UInt64, readSize: Int) -> UInt64? {
        // Zero-byte files all share the same partial hash.
        if fileSize == 0 { return 0 }

        let fd = open(cPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

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
        return Self.fnv1a(rawBuffer)
    }

    /// Compute a full-file 128-bit hash using streaming read(), via StreamingHash128.
    /// Uses read() instead of mmap to avoid SIGBUS if another process truncates
    /// the file while we're hashing it (mmap would crash the entire app).
    /// Returns 128 bits (two UInt64s) to minimise collision risk without the
    /// overhead of a cryptographic hash function.
    private static func fullFileHash(cPath: UnsafePointer<CChar>) -> (lo: UInt64, hi: UInt64)? {
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

        var hasher = StreamingHash128()
        var remaining = byteCount
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            let bytesRead = read(fd, buffer, toRead)
            // Error or unexpected EOF (file truncated by another process).
            guard bytesRead > 0 else { return nil }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            remaining -= bytesRead
        }

        return hasher.finalize()
    }
}

// MARK: - Internal Key Type

/// Pass 2 key: (size, FNV-1a partial hash). UInt64 is fine as a pre-filter.
private struct PartialHashKey: Hashable {
    let size: UInt64
    let hash: UInt64
}

/// Pass 3 key: (size, 128-bit StreamingHash128 digest). Using 128 bits instead
/// of 64 reduces collision probability from 2^-64 to 2^-128 for the same cost.
private struct FullHashKey: Hashable {
    let size: UInt64
    let lo: UInt64
    let hi: UInt64
}

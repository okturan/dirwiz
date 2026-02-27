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

/// Thread-safe counter for reporting progress from concurrent tasks
/// independently of task completion. The timer reads this while workers
/// increment it per-file, so the UI advances even when individual tasks
/// are blocked on large file I/O.
final class ProgressCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    func add(_ n: Int) { lock.lock(); _value += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

/// GCD-based timer bridge that reads a `ProgressCounter` every 250ms on a
/// real OS thread and dispatches progress updates to the main actor.
/// Unlike `Task.sleep`, GCD timers are not affected by cooperative pool
/// starvation — they fire reliably even when all Swift Concurrency threads
/// are busy hashing files.
private final class ProgressTimerBridge: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(
        phase: DuplicateScanPhase,
        total: Int,
        counter: ProgressCounter,
        progress: (@MainActor @Sendable (DuplicateScanUpdate) -> Void)?
    ) {
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [counter] in
            let current = counter.value
            guard current > 0 else { return }
            let update = DuplicateScanUpdate(
                phase: phase,
                processed: min(current, total),
                total: total
            )
            Task { @MainActor in
                progress?(update)
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }
}

/// GCD timer for simple (processed, total) progress handlers (used by HardlinkFinder).
final class DeterminateProgressTimer: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(
        total: Int,
        counter: ProgressCounter,
        progress: (@MainActor @Sendable (_ processed: Int, _ total: Int) -> Void)?
    ) {
        self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [counter] in
            let current = counter.value
            guard current > 0 else { return }
            let clamped = min(current, total)
            Task { @MainActor in
                progress?(clamped, total)
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }
}

// MARK: - DuplicateFinder

public enum DuplicateScanPhase: Sendable, Hashable {
    case groupingBySize
    case partialHashing
    case fullHashing
    case finalizing

    public var message: String {
        switch self {
        case .groupingBySize:
            return "Grouping files by size…"
        case .partialHashing:
            return "Hashing candidates…"
        case .fullHashing:
            return "Verifying matching hashes…"
        case .finalizing:
            return "Building duplicate groups…"
        }
    }

    public var unitLabel: String {
        switch self {
        case .groupingBySize:
            return "items"
        case .partialHashing, .fullHashing:
            return "candidates"
        case .finalizing:
            return "groups"
        }
    }
}

public struct DuplicateScanUpdate: Sendable {
    public let phase: DuplicateScanPhase
    public let processed: Int
    public let total: Int

    public init(phase: DuplicateScanPhase, processed: Int, total: Int) {
        self.phase = phase
        self.processed = processed
        self.total = total
    }
}

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
    ///   - progress: Optional progress callback for the current scan phase.
    /// - Returns: Array of DuplicateGroup sorted by wastedSpace descending.
    public func findDuplicates(
        in tree: FileTree,
        progress: (@MainActor @Sendable (DuplicateScanUpdate) -> Void)? = nil
    ) async -> [DuplicateGroup] {

        // ---------------------------------------------------------------
        // Pass 1: Group files by size
        // ---------------------------------------------------------------
        let snapshot = tree.nodesSnapshot()
        var sizeGroups: [UInt64: [UInt32]] = [:]
        sizeGroups.reserveCapacity(snapshot.count / 2)
        let groupingTotal = snapshot.count
        var lastGroupingProgressTime = CFAbsoluteTimeGetCurrent()

        for i in 0..<snapshot.count {
            if Task.isCancelled { return [] }

            let node = snapshot[i]
            if !node.isDirectory, node.fileSize >= minimumFileSize {
                sizeGroups[node.fileSize, default: []].append(UInt32(i))
            }

            let now = CFAbsoluteTimeGetCurrent()
            let processed = i + 1
            if now - lastGroupingProgressTime >= 0.2 || processed == groupingTotal {
                lastGroupingProgressTime = now
                await progress?(DuplicateScanUpdate(
                    phase: .groupingBySize,
                    processed: processed,
                    total: groupingTotal
                ))
            }
        }

        // Remove unique sizes (can't be duplicates)
        sizeGroups = sizeGroups.filter { $0.value.count >= 2 }

        // Flatten candidates for progress reporting
        let candidateGroups = Array(sizeGroups.values)
        let totalCandidates = candidateGroups.reduce(0) { $0 + $1.count }

        if totalCandidates == 0 {
            await progress?(DuplicateScanUpdate(phase: .finalizing, processed: 0, total: 0))
            return []
        }

        // ---------------------------------------------------------------
        // Pass 2: Partial hash (first 4KB + last 4KB)
        // ---------------------------------------------------------------
        let readSize = partialReadSize

        // Collect partial-hash groups using TaskGroup for concurrency.
        // Split very large same-size groups so progress can advance during hashing
        // instead of waiting for one giant batch to finish.
        let maxPartialFilesPerWorkItem = 64
        let maxFullFilesPerWorkItem = 8
        struct PartialWorkItem: Sendable {
            let fileSize: UInt64
            let indices: ArraySlice<UInt32>
        }
        var partialWorkItems: [PartialWorkItem] = []
        partialWorkItems.reserveCapacity(candidateGroups.count)
        for sizeGroup in candidateGroups {
            let fileSize = snapshot[Int(sizeGroup[0])].fileSize
            for start in stride(from: 0, to: sizeGroup.count, by: maxPartialFilesPerWorkItem) {
                let end = min(start + maxPartialFilesPerWorkItem, sizeGroup.count)
                partialWorkItems.append(PartialWorkItem(
                    fileSize: fileSize,
                    indices: sizeGroup[start..<end]
                ))
            }
        }

        await progress?(DuplicateScanUpdate(
            phase: .partialHashing,
            processed: 0,
            total: totalCandidates
        ))

        // Progress uses a GCD timer + shared counter so the UI updates even
        // when the `for await` consumer loop is starved by worker tasks on
        // the cooperative pool. Without this, 23K+ tasks saturate the pool
        // and the consumer never gets scheduled to report progress.
        let partialHashCounter = ProgressCounter()
        let partialProgressTimer = ProgressTimerBridge(
            phase: .partialHashing,
            total: totalCandidates,
            counter: partialHashCounter,
            progress: progress
        )

        let partialItemsPerTask = 1
        let fullItemsPerTask = 1
        typealias PartialBatch = [(PartialHashKey, UInt32)]
        let partialGroups: [PartialHashKey: [UInt32]] = await withTaskGroup(
            of: PartialBatch.self,
            returning: [PartialHashKey: [UInt32]].self
        ) { group in
            for chunkStart in stride(from: 0, to: partialWorkItems.count, by: partialItemsPerTask) {
                let chunkEnd = min(chunkStart + partialItemsPerTask, partialWorkItems.count)
                let chunk = partialWorkItems[chunkStart..<chunkEnd]
                group.addTask {
                    var results: [(PartialHashKey, UInt32)] = []
                    for workItem in chunk {
                        guard !Task.isCancelled else { break }
                        for nodeIndex in workItem.indices {
                            guard !Task.isCancelled else { break }
                            let hash = tree.withCPath(at: nodeIndex) { cPath in
                                Self.partialHash(cPath: cPath, fileSize: workItem.fileSize, readSize: readSize)
                            }
                            if let hash {
                                let key = PartialHashKey(size: workItem.fileSize, hash: hash)
                                results.append((key, nodeIndex))
                            }
                            partialHashCounter.add(1)
                        }
                    }
                    return results
                }
            }

            var collected: [PartialHashKey: [UInt32]] = [:]
            for await batch in group {
                for (key, nodeIndex) in batch {
                    collected[key, default: []].append(nodeIndex)
                }
            }
            return collected
        }

        partialProgressTimer.stop()
        await progress?(DuplicateScanUpdate(
            phase: .partialHashing,
            processed: totalCandidates,
            total: totalCandidates
        ))

        // Remove groups with only one member (partial hash unique)
        let partialMatches = partialGroups.filter { $0.value.count >= 2 }

        if partialMatches.isEmpty {
            await progress?(DuplicateScanUpdate(
                phase: .finalizing,
                processed: totalCandidates,
                total: totalCandidates
            ))
            return []
        }

        // ---------------------------------------------------------------
        // Pass 3: Full-file hash for remaining candidates
        // ---------------------------------------------------------------
        let partialMatchArray = Array(partialMatches)
        let totalFullCandidates = partialMatchArray.reduce(0) { $0 + $1.value.count }
        struct FullWorkItem: Sendable {
            let key: PartialHashKey
            let indices: ArraySlice<UInt32>
        }
        var fullWorkItems: [FullWorkItem] = []
        fullWorkItems.reserveCapacity(partialMatchArray.count)
        for (partialKey, indices) in partialMatchArray {
            for start in stride(from: 0, to: indices.count, by: maxFullFilesPerWorkItem) {
                let end = min(start + maxFullFilesPerWorkItem, indices.count)
                fullWorkItems.append(FullWorkItem(
                    key: partialKey,
                    indices: indices[start..<end]
                ))
            }
        }

        await progress?(DuplicateScanUpdate(
            phase: .fullHashing,
            processed: 0,
            total: totalFullCandidates
        ))

        // Full-hash progress uses a shared counter + GCD timer so progress
        // advances per-file even when a single large file blocks a task.
        // A GCD timer runs on a real OS thread, immune to Swift cooperative
        // pool starvation that happens when 400K+ hash tasks saturate it.
        let fullHashCounter = ProgressCounter()
        let fullProgressContinuation = ProgressTimerBridge(
            phase: .fullHashing,
            total: totalFullCandidates,
            counter: fullHashCounter,
            progress: progress
        )

        let fullGroups: [FullHashKey: [UInt32]] = await withTaskGroup(
            of: [(FullHashKey, UInt32)].self,
            returning: [FullHashKey: [UInt32]].self
        ) { group in
            for chunkStart in stride(from: 0, to: fullWorkItems.count, by: fullItemsPerTask) {
                let chunkEnd = min(chunkStart + fullItemsPerTask, fullWorkItems.count)
                let chunk = fullWorkItems[chunkStart..<chunkEnd]
                group.addTask {
                    var results: [(FullHashKey, UInt32)] = []
                    for workItem in chunk {
                        guard !Task.isCancelled else { break }
                        for nodeIndex in workItem.indices {
                            guard !Task.isCancelled else { break }
                            let digest = tree.withCPath(at: nodeIndex) { cPath in
                                Self.fullFileHash(cPath: cPath, expectedSize: workItem.key.size)
                            }
                            if let digest {
                                let key = FullHashKey(size: workItem.key.size, lo: digest.lo, hi: digest.hi)
                                results.append((key, nodeIndex))
                            }
                            fullHashCounter.add(1)
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

        fullProgressContinuation.stop()
        await progress?(DuplicateScanUpdate(
            phase: .fullHashing,
            processed: totalFullCandidates,
            total: totalFullCandidates
        ))

        // Build DuplicateGroup results from confirmed duplicates.
        // Filter out hardlinks: files sharing the same (device, inode) are hardlinks
        // and removing one doesn't free space, so keep only one representative per inode.
        struct DevIno: Hashable {
            let dev: Int32
            let ino: UInt64
        }
        var results: [DuplicateGroup] = []
        for (key, indices) in fullGroups {
            guard indices.count >= 2 else { continue }

            // Deduplicate by (device, inode) — hardlinked files share both.
            var seenInodes: [DevIno: String] = [:]  // first path per unique inode
            for nodeIndex in indices {
                let path = tree.path(at: nodeIndex)
                var st = Darwin.stat()
                guard lstat(path, &st) == 0 else { continue }
                let devIno = DevIno(dev: st.st_dev, ino: st.st_ino)
                if seenInodes[devIno] == nil {
                    seenInodes[devIno] = path
                }
            }

            let dedupedPaths = Array(seenInodes.values)
            guard dedupedPaths.count >= 2 else { continue }

            let dupGroup = DuplicateGroup(
                fileSize: key.size,
                hash: key.lo,  // Lower 64 bits for display identity
                paths: dedupedPaths
            )
            results.append(dupGroup)
        }

        // Sort by wasted space descending
        results.sort { $0.wastedSpace > $1.wastedSpace }

        await progress?(DuplicateScanUpdate(
            phase: .finalizing,
            processed: results.count,
            total: results.count
        ))
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

    /// Read exactly `count` bytes into `dst`, retrying on EINTR and short reads.
    /// Returns true only if all `count` bytes were read; false on EOF-before-count or error.
    private static func readExact(_ fd: Int32, _ dst: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var ptr = dst
        var remaining = count
        while remaining > 0 {
            let n = Darwin.read(fd, ptr, remaining)
            if n == -1 && errno == EINTR { continue }
            guard n > 0 else { return false }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
        return true
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
            // Read entire small file.
            guard readExact(fd, buffer, totalRead) else { return nil }
        } else {
            // Read first 4KB.
            guard readExact(fd, buffer, readSize) else { return nil }

            // Seek to last 4KB.
            let seekPos = off_t(fileSize) - off_t(readSize)
            guard lseek(fd, seekPos, SEEK_SET) == seekPos else { return nil }

            guard readExact(fd, buffer.advanced(by: readSize), readSize) else { return nil }
        }

        let rawBuffer = UnsafeRawBufferPointer(start: buffer, count: totalRead)
        return Self.fnv1a(rawBuffer)
    }

    /// Compute a full-file 128-bit hash using streaming read(), via StreamingHash128.
    /// Uses read() instead of mmap to avoid SIGBUS if another process truncates
    /// the file while we're hashing it (mmap would crash the entire app).
    /// Returns 128 bits (two UInt64s) to minimise collision risk without the
    /// overhead of a cryptographic hash function.
    private static func fullFileHash(
        cPath: UnsafePointer<CChar>,
        expectedSize: UInt64
    ) -> (lo: UInt64, hi: UInt64)? {
        let fd = open(cPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else { return nil }
        // Reject files that mutated between the directory scan and now (TOCTOU).
        guard UInt64(bitPattern: Int64(fileInfo.st_size)) == expectedSize else { return nil }
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
            // readExact retries EINTR and short reads; returns false on EOF or error.
            guard readExact(fd, buffer, toRead) else { return nil }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: toRead))
            remaining -= toRead
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

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
///  - Full-file hash matches are only candidates; a final byte-for-byte pass
///    confirms duplicate groups before cleanup actions can use them.
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

private struct PartialHashPlan: Sendable {
    let sampleSize: Int
    let includeMiddle: Bool
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

public struct DuplicateScanStats: Sendable {
    public let groupingSeconds: TimeInterval
    public let partialHashingSeconds: TimeInterval
    public let fullHashingSeconds: TimeInterval
    public let finalizingSeconds: TimeInterval
    public let sizeQualifiedFiles: Int
    public let sizeCollisionGroups: Int
    public let totalCandidates: Int
    public let partialHashedFiles: Int
    public let partialBytesRequested: UInt64
    public let partialInlineConfirmedFiles: Int
    public let partialInlineConfirmedBytesRequested: UInt64
    public let partialDefaultSampledFiles: Int
    public let partialDefaultSampledBytesRequested: UInt64
    public let partialLargeGroupSampledFiles: Int
    public let partialLargeGroupSampledBytesRequested: UInt64
    public let partialMatchGroups: Int
    public let totalFullCandidates: Int
    public let fullHashedFiles: Int
    public let fullBytesRequested: UInt64
    public let confirmedGroups: Int

    public init(
        groupingSeconds: TimeInterval,
        partialHashingSeconds: TimeInterval,
        fullHashingSeconds: TimeInterval,
        finalizingSeconds: TimeInterval,
        sizeQualifiedFiles: Int,
        sizeCollisionGroups: Int,
        totalCandidates: Int,
        partialHashedFiles: Int,
        partialBytesRequested: UInt64,
        partialInlineConfirmedFiles: Int,
        partialInlineConfirmedBytesRequested: UInt64,
        partialDefaultSampledFiles: Int,
        partialDefaultSampledBytesRequested: UInt64,
        partialLargeGroupSampledFiles: Int,
        partialLargeGroupSampledBytesRequested: UInt64,
        partialMatchGroups: Int,
        totalFullCandidates: Int,
        fullHashedFiles: Int,
        fullBytesRequested: UInt64,
        confirmedGroups: Int
    ) {
        self.groupingSeconds = groupingSeconds
        self.partialHashingSeconds = partialHashingSeconds
        self.fullHashingSeconds = fullHashingSeconds
        self.finalizingSeconds = finalizingSeconds
        self.sizeQualifiedFiles = sizeQualifiedFiles
        self.sizeCollisionGroups = sizeCollisionGroups
        self.totalCandidates = totalCandidates
        self.partialHashedFiles = partialHashedFiles
        self.partialBytesRequested = partialBytesRequested
        self.partialInlineConfirmedFiles = partialInlineConfirmedFiles
        self.partialInlineConfirmedBytesRequested = partialInlineConfirmedBytesRequested
        self.partialDefaultSampledFiles = partialDefaultSampledFiles
        self.partialDefaultSampledBytesRequested = partialDefaultSampledBytesRequested
        self.partialLargeGroupSampledFiles = partialLargeGroupSampledFiles
        self.partialLargeGroupSampledBytesRequested = partialLargeGroupSampledBytesRequested
        self.partialMatchGroups = partialMatchGroups
        self.totalFullCandidates = totalFullCandidates
        self.fullHashedFiles = fullHashedFiles
        self.fullBytesRequested = fullBytesRequested
        self.confirmedGroups = confirmedGroups
    }
}

public struct DuplicateScanReport: Sendable {
    public let groups: [DuplicateGroup]
    public let stats: DuplicateScanStats

    public init(groups: [DuplicateGroup], stats: DuplicateScanStats) {
        self.groups = groups
        self.stats = stats
    }
}

/// Two-pass duplicate file detection engine.
///
/// Pass 1: Group files by size. Unique sizes cannot be duplicates (eliminates ~80%).
/// Pass 2: For size-matched groups, read strategic samples and hash them. Small files that
///         fit entirely in this pass also get their full-file digest here, avoiding a reread.
/// Pass 3: For remaining candidates, compute full-file hash.
/// Pass 4: Byte-compare hash matches before returning trashable duplicate groups.
public final class DuplicateFinder {

    /// Minimum file size to consider. Files under this threshold are skipped.
    /// Set to 1 to exclude zero-byte files (e.g., .gitkeep, .DS_Store stubs) —
    /// they are technically "duplicates" of each other but not useful to report.
    private let minimumFileSize: UInt64

    /// Bytes to read from head and tail for partial hashing.
    private let partialReadSize = 4096
    /// Large same-size groups are the main duplicate-scan cliff. For those groups,
    /// use smaller multi-point samples so we reduce partial-pass I/O without
    /// blindly promoting everything to full hashing.
    private let largeGroupThreshold = 64
    private let largeGroupSampleSize = 1024

    public init(minimumFileSize: UInt64 = 1) {
        self.minimumFileSize = max(1, minimumFileSize)
    }

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
        let report = await findDuplicatesWithStats(in: tree, progress: progress)
        return report.groups
    }

    public func findDuplicatesWithStats(
        in tree: FileTree,
        progress: (@MainActor @Sendable (DuplicateScanUpdate) -> Void)? = nil
    ) async -> DuplicateScanReport {
        let (snapshotNodes, snapshotStringPool, snapshotRootPath) = tree.pathBuildingSnapshot()
        let overallStart = CFAbsoluteTimeGetCurrent()

        // ---------------------------------------------------------------
        // Pass 1: Group files by size
        // ---------------------------------------------------------------
        let snapshot = snapshotNodes
        var sizeGroups: [UInt64: [UInt32]] = [:]
        sizeGroups.reserveCapacity(snapshot.count / 2)
        let groupingTotal = snapshot.count
        var lastGroupingProgressTime = CFAbsoluteTimeGetCurrent()
        var sizeQualifiedFiles = 0

        for i in 0..<snapshot.count {
            if Task.isCancelled {
                return DuplicateScanReport(groups: [], stats: Self.emptyStats(totalFiles: sizeQualifiedFiles))
            }

            let node = snapshot[i]
            if !node.isDirectory, node.fileSize >= minimumFileSize {
                sizeGroups[node.fileSize, default: []].append(UInt32(i))
                sizeQualifiedFiles += 1
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
        let sizeCollisionGroups = sizeGroups.count

        // Flatten candidates for progress reporting
        let candidateGroups = Array(sizeGroups.values)
        let totalCandidates = candidateGroups.reduce(0) { $0 + $1.count }
        let groupingSeconds = CFAbsoluteTimeGetCurrent() - overallStart

        if totalCandidates == 0 {
            await progress?(DuplicateScanUpdate(phase: .finalizing, processed: 0, total: 0))
            return DuplicateScanReport(
                groups: [],
                stats: DuplicateScanStats(
                    groupingSeconds: groupingSeconds,
                    partialHashingSeconds: 0,
                    fullHashingSeconds: 0,
                    finalizingSeconds: 0,
                    sizeQualifiedFiles: sizeQualifiedFiles,
                    sizeCollisionGroups: sizeCollisionGroups,
                    totalCandidates: 0,
                    partialHashedFiles: 0,
                    partialBytesRequested: 0,
                    partialInlineConfirmedFiles: 0,
                    partialInlineConfirmedBytesRequested: 0,
                    partialDefaultSampledFiles: 0,
                    partialDefaultSampledBytesRequested: 0,
                    partialLargeGroupSampledFiles: 0,
                    partialLargeGroupSampledBytesRequested: 0,
                    partialMatchGroups: 0,
                    totalFullCandidates: 0,
                    fullHashedFiles: 0,
                    fullBytesRequested: 0,
                    confirmedGroups: 0
                )
            )
        }

        // ---------------------------------------------------------------
        // Pass 2: Partial hash (first 4KB + last 4KB)
        // ---------------------------------------------------------------
        let partialStart = CFAbsoluteTimeGetCurrent()
        // Collect partial-hash groups using TaskGroup for concurrency.
        // Split very large same-size groups so progress can advance during hashing
        // instead of waiting for one giant batch to finish.
        let maxPartialFilesPerWorkItem = 64
        let maxFullFilesPerWorkItem = 8
        struct PartialWorkItem: Sendable {
            let fileSize: UInt64
            let indices: ArraySlice<UInt32>
            let plan: PartialHashPlan
        }
        var partialWorkItems: [PartialWorkItem] = []
        partialWorkItems.reserveCapacity(candidateGroups.count)
        for sizeGroup in candidateGroups {
            let fileSize = snapshot[Int(sizeGroup[0])].fileSize
            let plan = makePartialHashPlan(fileSize: fileSize, groupCount: sizeGroup.count)
            for start in stride(from: 0, to: sizeGroup.count, by: maxPartialFilesPerWorkItem) {
                let end = min(start + maxPartialFilesPerWorkItem, sizeGroup.count)
                partialWorkItems.append(PartialWorkItem(
                    fileSize: fileSize,
                    indices: sizeGroup[start..<end],
                    plan: plan
                ))
            }
        }
        // Preserve per-group ordering, but process groups in scan order so hashing
        // walks nearby files together instead of hash-table order across the disk.
        partialWorkItems.sort { ($0.indices.first ?? UInt32.max) < ($1.indices.first ?? UInt32.max) }

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

        struct PartialBatchReport: Sendable {
            let partialPairs: [(PartialHashKey, UInt32)]
            let fullPairs: [(FullHashKey, UInt32)]
            let hashedFiles: Int
            let bytesRequested: UInt64
            let inlineConfirmedFiles: Int
            let inlineConfirmedBytesRequested: UInt64
            let defaultSampledFiles: Int
            let defaultSampledBytesRequested: UInt64
            let largeGroupSampledFiles: Int
            let largeGroupSampledBytesRequested: UInt64
        }
        let partialStage = await withTaskGroup(
            of: PartialBatchReport.self,
            returning: (
                partialGroups: [PartialHashKey: [UInt32]],
                preconfirmedFullGroups: [FullHashKey: [UInt32]],
                hashedFiles: Int,
                bytesRequested: UInt64,
                inlineConfirmedFiles: Int,
                inlineConfirmedBytesRequested: UInt64,
                defaultSampledFiles: Int,
                defaultSampledBytesRequested: UInt64,
                largeGroupSampledFiles: Int,
                largeGroupSampledBytesRequested: UInt64
            ).self
        ) { group in
            var partialHashedFiles = 0
            var partialBytesRequested: UInt64 = 0
            var partialInlineConfirmedFiles = 0
            var partialInlineConfirmedBytesRequested: UInt64 = 0
            var partialDefaultSampledFiles = 0
            var partialDefaultSampledBytesRequested: UInt64 = 0
            var partialLargeGroupSampledFiles = 0
            var partialLargeGroupSampledBytesRequested: UInt64 = 0
            for workItem in partialWorkItems {
                group.addTask {
                    var partialResults: [(PartialHashKey, UInt32)] = []
                    var fullResults: [(FullHashKey, UInt32)] = []
                    var hashedFiles = 0
                    var bytesRequested: UInt64 = 0
                    var inlineConfirmedFiles = 0
                    var inlineConfirmedBytesRequested: UInt64 = 0
                    var defaultSampledFiles = 0
                    var defaultSampledBytesRequested: UInt64 = 0
                    var largeGroupSampledFiles = 0
                    var largeGroupSampledBytesRequested: UInt64 = 0
                    let partialBufferCapacity = self.partialReadSize * 2
                    let partialBuffer = UnsafeMutableRawPointer.allocate(byteCount: partialBufferCapacity, alignment: 8)
                    defer { partialBuffer.deallocate() }
                    for nodeIndex in workItem.indices {
                        guard !Task.isCancelled else { break }
                        hashedFiles += 1
                        let result = FileTree.withCPathFromSnapshot(
                            at: nodeIndex,
                            nodes: snapshotNodes,
                            stringPool: snapshotStringPool,
                            rootPath: snapshotRootPath
                        ) { cPath in
                            Self.partialHash(
                                cPath: cPath,
                                fileSize: workItem.fileSize,
                                plan: workItem.plan,
                                scratchBuffer: partialBuffer,
                                scratchCapacity: partialBufferCapacity
                            )
                        }
                        if let result {
                            bytesRequested += result.bytesRequested
                            if let digest = result.fullDigest {
                                inlineConfirmedFiles += 1
                                inlineConfirmedBytesRequested += result.bytesRequested
                                let key = FullHashKey(size: workItem.fileSize, lo: digest.lo, hi: digest.hi)
                                fullResults.append((key, nodeIndex))
                            } else {
                                if workItem.plan.includeMiddle {
                                    largeGroupSampledFiles += 1
                                    largeGroupSampledBytesRequested += result.bytesRequested
                                } else {
                                    defaultSampledFiles += 1
                                    defaultSampledBytesRequested += result.bytesRequested
                                }
                                let key = PartialHashKey(size: workItem.fileSize, hash: result.hash)
                                partialResults.append((key, nodeIndex))
                            }
                        }
                        partialHashCounter.add(1)
                    }
                    return PartialBatchReport(
                        partialPairs: partialResults,
                        fullPairs: fullResults,
                        hashedFiles: hashedFiles,
                        bytesRequested: bytesRequested,
                        inlineConfirmedFiles: inlineConfirmedFiles,
                        inlineConfirmedBytesRequested: inlineConfirmedBytesRequested,
                        defaultSampledFiles: defaultSampledFiles,
                        defaultSampledBytesRequested: defaultSampledBytesRequested,
                        largeGroupSampledFiles: largeGroupSampledFiles,
                        largeGroupSampledBytesRequested: largeGroupSampledBytesRequested
                    )
                }
            }

            var collectedPartial: [PartialHashKey: [UInt32]] = [:]
            var collectedFull: [FullHashKey: [UInt32]] = [:]
            for await batch in group {
                partialHashedFiles += batch.hashedFiles
                partialBytesRequested += batch.bytesRequested
                partialInlineConfirmedFiles += batch.inlineConfirmedFiles
                partialInlineConfirmedBytesRequested += batch.inlineConfirmedBytesRequested
                partialDefaultSampledFiles += batch.defaultSampledFiles
                partialDefaultSampledBytesRequested += batch.defaultSampledBytesRequested
                partialLargeGroupSampledFiles += batch.largeGroupSampledFiles
                partialLargeGroupSampledBytesRequested += batch.largeGroupSampledBytesRequested
                for (key, nodeIndex) in batch.partialPairs {
                    collectedPartial[key, default: []].append(nodeIndex)
                }
                for (key, nodeIndex) in batch.fullPairs {
                    collectedFull[key, default: []].append(nodeIndex)
                }
            }
            return (
                collectedPartial,
                collectedFull,
                partialHashedFiles,
                partialBytesRequested,
                partialInlineConfirmedFiles,
                partialInlineConfirmedBytesRequested,
                partialDefaultSampledFiles,
                partialDefaultSampledBytesRequested,
                partialLargeGroupSampledFiles,
                partialLargeGroupSampledBytesRequested
            )
        }
        let partialGroups = partialStage.partialGroups
        let preconfirmedFullGroups = partialStage.preconfirmedFullGroups.filter { $0.value.count >= 2 }
        let partialHashedFiles = partialStage.hashedFiles
        let partialBytesRequested = partialStage.bytesRequested
        let partialInlineConfirmedFiles = partialStage.inlineConfirmedFiles
        let partialInlineConfirmedBytesRequested = partialStage.inlineConfirmedBytesRequested
        let partialDefaultSampledFiles = partialStage.defaultSampledFiles
        let partialDefaultSampledBytesRequested = partialStage.defaultSampledBytesRequested
        let partialLargeGroupSampledFiles = partialStage.largeGroupSampledFiles
        let partialLargeGroupSampledBytesRequested = partialStage.largeGroupSampledBytesRequested
        let partialHashingSeconds = CFAbsoluteTimeGetCurrent() - partialStart

        partialProgressTimer.stop()
        await progress?(DuplicateScanUpdate(
            phase: .partialHashing,
            processed: totalCandidates,
            total: totalCandidates
        ))

        // Remove groups with only one member (partial hash unique)
        let partialMatches = partialGroups.filter { $0.value.count >= 2 }
        let partialMatchGroups = partialMatches.count

        if partialMatches.isEmpty, preconfirmedFullGroups.isEmpty {
            await progress?(DuplicateScanUpdate(
                phase: .finalizing,
                processed: totalCandidates,
                total: totalCandidates
            ))
            return DuplicateScanReport(
                groups: [],
                stats: DuplicateScanStats(
                    groupingSeconds: groupingSeconds,
                    partialHashingSeconds: partialHashingSeconds,
                    fullHashingSeconds: 0,
                    finalizingSeconds: 0,
                    sizeQualifiedFiles: sizeQualifiedFiles,
                    sizeCollisionGroups: sizeCollisionGroups,
                    totalCandidates: totalCandidates,
                    partialHashedFiles: partialHashedFiles,
                    partialBytesRequested: partialBytesRequested,
                    partialInlineConfirmedFiles: partialInlineConfirmedFiles,
                    partialInlineConfirmedBytesRequested: partialInlineConfirmedBytesRequested,
                    partialDefaultSampledFiles: partialDefaultSampledFiles,
                    partialDefaultSampledBytesRequested: partialDefaultSampledBytesRequested,
                    partialLargeGroupSampledFiles: partialLargeGroupSampledFiles,
                    partialLargeGroupSampledBytesRequested: partialLargeGroupSampledBytesRequested,
                    partialMatchGroups: partialMatchGroups,
                    totalFullCandidates: 0,
                    fullHashedFiles: 0,
                    fullBytesRequested: 0,
                    confirmedGroups: 0
                )
            )
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
        var confirmedFullGroups = preconfirmedFullGroups
        let fullHashedFiles: Int
        let fullBytesRequested: UInt64
        let fullHashingSeconds: TimeInterval

        if totalFullCandidates > 0 {
            let fullStart = CFAbsoluteTimeGetCurrent()
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
            // Preserve per-group ordering, but hash in scan order to improve path and
            // filesystem locality for the remaining read-heavy pass.
            fullWorkItems.sort { ($0.indices.first ?? UInt32.max) < ($1.indices.first ?? UInt32.max) }

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

            struct FullBatchReport: Sendable {
                let pairs: [(FullHashKey, UInt32)]
                let hashedFiles: Int
                let bytesRequested: UInt64
            }
            let fullStage = await withTaskGroup(
                of: FullBatchReport.self,
                returning: (groups: [FullHashKey: [UInt32]], hashedFiles: Int, bytesRequested: UInt64).self
            ) { group in
                var stageFullHashedFiles = 0
                var stageFullBytesRequested: UInt64 = 0
                for workItem in fullWorkItems {
                    group.addTask {
                        var results: [(FullHashKey, UInt32)] = []
                        var hashedFiles = 0
                        var bytesRequested: UInt64 = 0
                        let fullBufferCapacity = 128 * 1024
                        let fullBuffer = UnsafeMutableRawPointer.allocate(byteCount: fullBufferCapacity, alignment: 8)
                        defer { fullBuffer.deallocate() }
                        for nodeIndex in workItem.indices {
                            guard !Task.isCancelled else { break }
                            hashedFiles += 1
                            let result = FileTree.withCPathFromSnapshot(
                                at: nodeIndex,
                                nodes: snapshotNodes,
                                stringPool: snapshotStringPool,
                                rootPath: snapshotRootPath
                            ) { cPath in
                                Self.fullFileHash(
                                    cPath: cPath,
                                    expectedSize: workItem.key.size,
                                    scratchBuffer: fullBuffer,
                                    scratchCapacity: fullBufferCapacity
                                )
                            }
                            if let result {
                                bytesRequested += result.bytesRequested
                                let digest = result.digest
                                let key = FullHashKey(size: workItem.key.size, lo: digest.lo, hi: digest.hi)
                                results.append((key, nodeIndex))
                            }
                            fullHashCounter.add(1)
                        }
                        return FullBatchReport(
                            pairs: results,
                            hashedFiles: hashedFiles,
                            bytesRequested: bytesRequested
                        )
                    }
                }

                var collected: [FullHashKey: [UInt32]] = [:]
                for await batch in group {
                    stageFullHashedFiles += batch.hashedFiles
                    stageFullBytesRequested += batch.bytesRequested
                    for (key, nodeIndex) in batch.pairs {
                        collected[key, default: []].append(nodeIndex)
                    }
                }
                return (collected, stageFullHashedFiles, stageFullBytesRequested)
            }
            fullHashedFiles = fullStage.hashedFiles
            fullBytesRequested = fullStage.bytesRequested
            fullHashingSeconds = CFAbsoluteTimeGetCurrent() - fullStart

            fullProgressContinuation.stop()
            await progress?(DuplicateScanUpdate(
                phase: .fullHashing,
                processed: totalFullCandidates,
                total: totalFullCandidates
            ))

            for (key, indices) in fullStage.groups {
                confirmedFullGroups[key, default: []].append(contentsOf: indices)
            }
        } else {
            fullHashedFiles = 0
            fullBytesRequested = 0
            fullHashingSeconds = 0
        }

        // Build DuplicateGroup results from confirmed duplicates.
        // Filter out hardlinks: files sharing the same (device, inode) are hardlinks
        // and removing one doesn't free space, so keep only one representative per inode.
        // Then byte-compare every remaining hash match before exposing it to the UI/CLI.
        let finalizingStart = CFAbsoluteTimeGetCurrent()
        struct DevIno: Hashable {
            let dev: Int32
            let ino: UInt64
        }
        func devIno(for nodeIndex: UInt32) -> DevIno? {
            let i = Int(nodeIndex)
            guard i < snapshotNodes.count else { return nil }
            let node = snapshotNodes[i]
            if node.inode != 0 || node.device != 0 {
                return DevIno(dev: node.device, ino: node.inode)
            }

            let path = FileTree.pathFromSnapshot(
                at: nodeIndex,
                nodes: snapshotNodes,
                stringPool: snapshotStringPool,
                rootPath: snapshotRootPath
            )
            var st = Darwin.stat()
            guard lstat(path, &st) == 0 else { return nil }
            return DevIno(dev: st.st_dev, ino: st.st_ino)
        }
        // Process candidate groups in a fixed, deterministic order (independent of
        // Dictionary iteration order) so parallel completion order can't change the
        // pre-sort ordering used to break ties in the wastedSpace sort below.
        let finalizeWorkItems = confirmedFullGroups.sorted { lhs, rhs in
            if lhs.key.size != rhs.key.size { return lhs.key.size < rhs.key.size }
            if lhs.key.lo != rhs.key.lo { return lhs.key.lo < rhs.key.lo }
            return lhs.key.hi < rhs.key.hi
        }

        var results: [DuplicateGroup] = []
        if !finalizeWorkItems.isEmpty {
            await progress?(DuplicateScanUpdate(
                phase: .finalizing,
                processed: 0,
                total: finalizeWorkItems.count
            ))

            // Same GCD-timer + shared-counter bridge as passes 2/3: progress is
            // counted per completed group (not per file within a group), and the
            // timer keeps the UI advancing even if a large group's byte-verification
            // blocks its task for a while.
            let finalizeCounter = ProgressCounter()
            let finalizeProgressTimer = ProgressTimerBridge(
                phase: .finalizing,
                total: finalizeWorkItems.count,
                counter: finalizeCounter,
                progress: progress
            )

            struct FinalizeGroupReport: Sendable {
                let index: Int
                let groups: [DuplicateGroup]
            }

            let orderedGroups = await withTaskGroup(
                of: FinalizeGroupReport.self,
                returning: [[DuplicateGroup]].self
            ) { group in
                for (index, entry) in finalizeWorkItems.enumerated() {
                    group.addTask {
                        defer { finalizeCounter.add(1) }
                        guard !Task.isCancelled else {
                            return FinalizeGroupReport(index: index, groups: [])
                        }

                        let key = entry.key
                        let indices = entry.value
                        guard indices.count >= 2 else {
                            return FinalizeGroupReport(index: index, groups: [])
                        }

                        // Deduplicate by scan-time (device, inode) metadata — hardlinked files share both.
                        // This avoids a path rebuild + lstat round-trip for every confirmed file.
                        var seenInodes: [DevIno: UInt32] = [:]
                        for nodeIndex in indices {
                            guard let devIno = devIno(for: nodeIndex) else { continue }
                            if seenInodes[devIno] == nil {
                                seenInodes[devIno] = nodeIndex
                            }
                        }

                        let dedupedPaths = seenInodes.values.map { nodeIndex in
                            FileTree.pathFromSnapshot(
                                at: nodeIndex,
                                nodes: snapshotNodes,
                                stringPool: snapshotStringPool,
                                rootPath: snapshotRootPath
                            )
                        }.sorted()
                        guard dedupedPaths.count >= 2 else {
                            return FinalizeGroupReport(index: index, groups: [])
                        }

                        let verifiedGroups = DuplicateContentVerifier
                            .exactGroups(paths: dedupedPaths, expectedSize: key.size)
                            .map { exactPaths in
                                DuplicateGroup(
                                    fileSize: key.size,
                                    hash: key.lo,  // Lower 64 bits for display identity
                                    paths: exactPaths
                                )
                            }
                        return FinalizeGroupReport(index: index, groups: verifiedGroups)
                    }
                }

                var slots = [[DuplicateGroup]](repeating: [], count: finalizeWorkItems.count)
                for await report in group {
                    slots[report.index] = report.groups
                }
                return slots
            }

            finalizeProgressTimer.stop()
            for groups in orderedGroups {
                results.append(contentsOf: groups)
            }
        }

        // Sort by wasted space descending
        results.sort { $0.wastedSpace > $1.wastedSpace }

        await progress?(DuplicateScanUpdate(
            phase: .finalizing,
            processed: finalizeWorkItems.count,
            total: finalizeWorkItems.count
        ))
        let finalizingSeconds = CFAbsoluteTimeGetCurrent() - finalizingStart
        return DuplicateScanReport(
            groups: results,
            stats: DuplicateScanStats(
                groupingSeconds: groupingSeconds,
                partialHashingSeconds: partialHashingSeconds,
                fullHashingSeconds: fullHashingSeconds,
                finalizingSeconds: finalizingSeconds,
                sizeQualifiedFiles: sizeQualifiedFiles,
                sizeCollisionGroups: sizeCollisionGroups,
                totalCandidates: totalCandidates,
                partialHashedFiles: partialHashedFiles,
                partialBytesRequested: partialBytesRequested,
                partialInlineConfirmedFiles: partialInlineConfirmedFiles,
                partialInlineConfirmedBytesRequested: partialInlineConfirmedBytesRequested,
                partialDefaultSampledFiles: partialDefaultSampledFiles,
                partialDefaultSampledBytesRequested: partialDefaultSampledBytesRequested,
                partialLargeGroupSampledFiles: partialLargeGroupSampledFiles,
                partialLargeGroupSampledBytesRequested: partialLargeGroupSampledBytesRequested,
                partialMatchGroups: partialMatchGroups,
                totalFullCandidates: totalFullCandidates,
                fullHashedFiles: fullHashedFiles,
                fullBytesRequested: fullBytesRequested,
                confirmedGroups: results.count
            )
        )
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

    /// Read exactly `count` bytes at `offset` without disturbing the file cursor.
    private static func preadExact(
        _ fd: Int32,
        _ dst: UnsafeMutableRawPointer,
        _ count: Int,
        _ offset: off_t
    ) -> Bool {
        var ptr = dst
        var remaining = count
        var currentOffset = offset
        while remaining > 0 {
            let n = Darwin.pread(fd, ptr, remaining, currentOffset)
            if n == -1 && errno == EINTR { continue }
            guard n > 0 else { return false }
            ptr = ptr.advanced(by: n)
            remaining -= n
            currentOffset += off_t(n)
        }
        return true
    }

    private func makePartialHashPlan(fileSize: UInt64, groupCount: Int) -> PartialHashPlan {
        if groupCount >= largeGroupThreshold, fileSize > UInt64(largeGroupSampleSize * 3) {
            return PartialHashPlan(sampleSize: largeGroupSampleSize, includeMiddle: true)
        }
        return PartialHashPlan(sampleSize: partialReadSize, includeMiddle: false)
    }

    /// Read a few strategic slices and compute a combined hash.
    /// For large same-size groups, use smaller head/middle/tail samples to cut
    /// random-read volume while still separating common "same header/footer"
    /// false positives before the full-hash pass.
    private static func partialHash(
        cPath: UnsafePointer<CChar>,
        fileSize: UInt64,
        plan: PartialHashPlan,
        scratchBuffer: UnsafeMutableRawPointer,
        scratchCapacity: Int
    ) -> (hash: UInt64, bytesRequested: UInt64, fullDigest: (lo: UInt64, hi: UInt64)?)? {
        // Zero-byte files all share the same partial hash.
        if fileSize == 0 { return (hash: 0, bytesRequested: 0, fullDigest: (0, 0)) }

        let fd = open(cPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let sampleSize = min(plan.sampleSize, Int(fileSize))
        let sampleCount = plan.includeMiddle ? 3 : 2
        let maxRead = sampleSize * sampleCount
        let totalRead = min(Int(fileSize), maxRead)
        guard totalRead <= scratchCapacity else { return nil }

        if fileSize <= UInt64(maxRead) {
            // Read entire small file.
            guard readExact(fd, scratchBuffer, totalRead) else { return nil }
            let rawBuffer = UnsafeRawBufferPointer(start: scratchBuffer, count: totalRead)
            var hasher = StreamingHash128()
            hasher.update(rawBuffer)
            return (
                hash: 0,
                bytesRequested: UInt64(totalRead),
                fullDigest: hasher.finalize()
            )
        } else {
            // Head sample.
            guard preadExact(fd, scratchBuffer, sampleSize, 0) else { return nil }

            var bytesWritten = sampleSize
            if plan.includeMiddle {
                let middleOffset = max(0, Int(fileSize / 2) - (sampleSize / 2))
                guard preadExact(fd, scratchBuffer.advanced(by: bytesWritten), sampleSize, off_t(middleOffset)) else {
                    return nil
                }
                bytesWritten += sampleSize
            }

            // Tail sample.
            let tailOffset = max(0, Int(fileSize) - sampleSize)
            guard preadExact(fd, scratchBuffer.advanced(by: bytesWritten), sampleSize, off_t(tailOffset)) else {
                return nil
            }
        }

        let rawBuffer = UnsafeRawBufferPointer(start: scratchBuffer, count: totalRead)
        return (hash: Self.fnv1a(rawBuffer), bytesRequested: UInt64(totalRead), fullDigest: nil)
    }

    /// Compute a full-file 128-bit hash using streaming read(), via StreamingHash128.
    /// Uses read() instead of mmap to avoid SIGBUS if another process truncates
    /// the file while we're hashing it (mmap would crash the entire app).
    /// Returns 128 bits (two UInt64s) to minimise collision risk without the
    /// overhead of a cryptographic hash function.
    private static func fullFileHash(
        cPath: UnsafePointer<CChar>,
        expectedSize: UInt64,
        scratchBuffer: UnsafeMutableRawPointer,
        scratchCapacity: Int
    ) -> (digest: (lo: UInt64, hi: UInt64), bytesRequested: UInt64)? {
        let fd = open(cPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else { return nil }
        // Reject files that mutated between the directory scan and now (TOCTOU).
        guard UInt64(bitPattern: Int64(fileInfo.st_size)) == expectedSize else { return nil }
        let byteCount = Int(fileInfo.st_size)

        // Zero-byte files are valid duplicates of each other.
        if byteCount == 0 { return (digest: (0, 0), bytesRequested: 0) }

        let chunkSize = 128 * 1024  // 128 KB read chunks
        guard chunkSize <= scratchCapacity else { return nil }

        var hasher = StreamingHash128()
        var remaining = byteCount
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            // readExact retries EINTR and short reads; returns false on EOF or error.
            guard readExact(fd, scratchBuffer, toRead) else { return nil }
            hasher.update(UnsafeRawBufferPointer(start: scratchBuffer, count: toRead))
            remaining -= toRead
        }

        return (digest: hasher.finalize(), bytesRequested: UInt64(byteCount))
    }
    private static func emptyStats(totalFiles: Int) -> DuplicateScanStats {
        DuplicateScanStats(
            groupingSeconds: 0,
            partialHashingSeconds: 0,
            fullHashingSeconds: 0,
            finalizingSeconds: 0,
            sizeQualifiedFiles: totalFiles,
            sizeCollisionGroups: 0,
            totalCandidates: 0,
            partialHashedFiles: 0,
            partialBytesRequested: 0,
            partialInlineConfirmedFiles: 0,
            partialInlineConfirmedBytesRequested: 0,
            partialDefaultSampledFiles: 0,
            partialDefaultSampledBytesRequested: 0,
            partialLargeGroupSampledFiles: 0,
            partialLargeGroupSampledBytesRequested: 0,
            partialMatchGroups: 0,
            totalFullCandidates: 0,
            fullHashedFiles: 0,
            fullBytesRequested: 0,
            confirmedGroups: 0
        )
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

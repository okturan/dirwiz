import Foundation
import Synchronization
import os

private let scanLog = Logger(subsystem: "com.dirwiz", category: "FileScanner")

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

// MARK: - Bundle Extension Set

private let kBundleExtensions: Set<String> = [
    "app", "framework", "xcarchive", "xcodeproj", "xcworkspace",
    "kext", "plugin", "bundle", "docset", "xpc",
    "qlgenerator", "mdimporter", "prefpane", "driver"
]
private let kBundleExtensionHashes: Set<UInt32> = Set(kBundleExtensions.map { extensionHash("x.\($0)") })

private func isBundleName(_ name: String) -> Bool {
    kBundleExtensionHashes.contains(extensionHash(name))
}

private func isBundleName(_ nameBytes: UnsafeBufferPointer<UInt8>) -> Bool {
    kBundleExtensionHashes.contains(extensionHash(nameBytes))
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

private struct DirectoryWorkItem: Sendable {
    let path: String
    let parentIndex: UInt32
}

private final class DirectoryWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [DirectoryWorkItem] = []
    private var active = 0
    private var closed = false

    func enqueue(path: String, parentIndex: UInt32) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        pending.append(DirectoryWorkItem(path: path, parentIndex: parentIndex))
        condition.signal()
    }

    func next() -> DirectoryWorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !closed {
            if active <= 0 {
                closed = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
        guard !pending.isEmpty else { return nil }
        active += 1
        return pending.removeLast()
    }

    func complete() {
        condition.lock()
        defer { condition.unlock() }
        active -= 1
        if pending.isEmpty && active <= 0 {
            closed = true
            condition.broadcast()
        }
    }

    func cancel() {
        condition.lock()
        pending.removeAll(keepingCapacity: true)
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// One unit of Phase A rescan work: a directory to enumerate, tagged with which
/// collapsed changed root it belongs to and which detached staging `FileTree` its
/// results go into. Distinct from `DirectoryWorkItem`/`DirectoryWorkQueue` (used by cold
/// scan) rather than generalizing those: `rescanSubtrees`'s Phase A shares ONE queue
/// across every changed root instead of one queue per root — a single worker pool that
/// drains whatever directory is next regardless of which root it came from, so a
/// worker isn't idle just because its own root ran out of work while another root (in
/// the incident's shape, ONE dominant root) still has plenty.
private struct RescanWorkItem: Sendable {
    let path: String
    let parentIndex: UInt32
    let rootPath: String
    let staging: FileTree
}

private final class RescanWorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [RescanWorkItem] = []
    private var active = 0
    private var closed = false

    func enqueue(_ item: RescanWorkItem) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        pending.append(item)
        condition.signal()
    }

    func next() -> RescanWorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty && !closed {
            if active <= 0 {
                closed = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
        guard !pending.isEmpty else { return nil }
        active += 1
        return pending.removeLast()
    }

    func complete() {
        condition.lock()
        defer { condition.unlock() }
        active -= 1
        if pending.isEmpty && active <= 0 {
            closed = true
            condition.broadcast()
        }
    }
}

/// Tracks how many enumeration items are still outstanding for each collapsed changed
/// root sharing the same `RescanWorkQueue`, so Phase A can report honest "k of N roots"
/// progress even though the queue itself has no notion of "root" — many workers may be
/// draining items that all belong to the SAME root, or to different ones, in any order.
/// Seeded with one pending item per root (its own root path); each discovered
/// subdirectory bumps its root's count, each finished item decrements it — the root is
/// fully enumerated the moment its count returns to zero.
private final class RootCompletionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingByRoot: [String: Int]

    init(rootPaths: [String]) {
        pendingByRoot = Dictionary(uniqueKeysWithValues: rootPaths.map { ($0, 1) })
    }

    func itemEnqueued(forRoot rootPath: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingByRoot[rootPath, default: 0] += 1
    }

    /// Returns true exactly once per root: the moment its outstanding count reaches zero.
    func itemCompleted(forRoot rootPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let count = pendingByRoot[rootPath] else { return false }
        let newCount = count - 1
        pendingByRoot[rootPath] = newCount
        return newCount == 0
    }
}

private struct RawScanScratch {
    var children: [EncodedFileNode] = []
    var namePool = Data()
    var subdirs: [(nameOffset: Int, nameLength: Int, childIndex: Int, dev: Int32, inode: UInt64)] = []
    var bundleDirs: [(nameOffset: Int, nameLength: Int, childIndex: Int)] = []

    init() {
        children.reserveCapacity(32)
        namePool.reserveCapacity(1024)
        subdirs.reserveCapacity(8)
        bundleDirs.reserveCapacity(2)
    }

    mutating func reset() {
        children.removeAll(keepingCapacity: true)
        namePool.removeAll(keepingCapacity: true)
        subdirs.removeAll(keepingCapacity: true)
        bundleDirs.removeAll(keepingCapacity: true)
    }
}

private final class DeferredTreeBuilder: @unchecked Sendable {
    private struct State: Sendable {
        var nextIndex: UInt32 = 1
        var childRanges: [UInt32: (first: UInt32, count: UInt32)] = [:]
    }

    private let state = Mutex(State())

    func reserveChildren(parentIndex: UInt32, count: Int) -> UInt32 {
        state.withLock { state in
            let firstIndex = state.nextIndex
            state.nextIndex &+= UInt32(count)
            state.childRanges[parentIndex] = (first: firstIndex, count: UInt32(count))
            return firstIndex
        }
    }

    func snapshot() -> (totalNodeCount: Int, childRanges: [UInt32: (first: UInt32, count: UInt32)]) {
        state.withLock { state in
            (totalNodeCount: Int(state.nextIndex), childRanges: state.childRanges)
        }
    }
}

private struct RawScanArena {
    var nodes: [IndexedEncodedFileNode] = []
    var namePool = Data()

    init() {
        nodes.reserveCapacity(8192)
        namePool.reserveCapacity(256 * 1024)
    }

    var isEmpty: Bool { nodes.isEmpty }

    mutating func append(
        children: [EncodedFileNode],
        localNamePool: Data,
        firstIndex: UInt32,
        parentIndex: UInt32
    ) {
        localNamePool.withUnsafeBytes { rawPool in
            let pool = rawPool.bindMemory(to: UInt8.self)
            for localIndex in children.indices {
                var node = children[localIndex].node
                node.parentIndex = parentIndex

                let child = children[localIndex]
                let sourceOffset = child.nameOffset
                let available = sourceOffset >= 0 && sourceOffset < pool.count
                    ? min(child.nameLength, pool.count - sourceOffset)
                    : 0
                let arenaOffset = namePool.count
                let length = min(available, Int(UInt16.max))

                if let base = pool.baseAddress, length > 0 {
                    namePool.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: sourceOffset), count: length))
                }

                nodes.append(IndexedEncodedFileNode(
                    index: firstIndex + UInt32(localIndex),
                    node: node,
                    nameOffset: arenaOffset,
                    nameLength: length
                ))
            }
        }
    }

    func export() -> FileTreeArena {
        FileTreeArena(nodes: nodes, namePool: namePool)
    }
}

public struct BundleSizeResolutionReport: Sendable {
    public let bundlesFound: Int
    public let bundlesResolved: Int
    public let totalFileSize: UInt64
    public let totalAllocatedSize: UInt64
    public let wasCancelled: Bool
}

/// Outcome of `FileScanner.rescanSubtrees`.
public struct SubtreeRescanReport: Sendable {
    public let requestedPaths: [String]
    /// Targets actually spliced, after ancestor-resolution + outermost-dedupe. A
    /// root-level entry here means some requested path couldn't resolve to anything
    /// narrower than the scan root — recorded honestly rather than silently absorbed;
    /// callers with a cold-fallback threshold (e.g. warm start) should treat it as a
    /// signal to prefer a full rescan.
    public let rescannedRoots: [String]
    /// Requested paths that weren't under the tree's root at all.
    public let unresolvedPaths: [String]
    /// True if cancellation (`FileScanner.cancel()`, or the enclosing `Task` itself being
    /// cancelled) was observed at any point during the rescan (plan 042) — some of
    /// `rescannedRoots` may not actually have been applied to the tree yet. The tree is
    /// left structurally valid either way (whatever finished applying stays applied, the
    /// rest is untouched), but callers should treat a cancelled rescan as incomplete
    /// rather than a normal completion — no cache write-back under the new event id, no
    /// "success" summary.
    public let wasCancelled: Bool

    public init(
        requestedPaths: [String],
        rescannedRoots: [String],
        unresolvedPaths: [String],
        wasCancelled: Bool = false
    ) {
        self.requestedPaths = requestedPaths
        self.rescannedRoots = rescannedRoots
        self.unresolvedPaths = unresolvedPaths
        self.wasCancelled = wasCancelled
    }
}

// MARK: - FileScanner

public final class FileScanner: @unchecked Sendable {

    private let cancelState = Mutex(false)
    private let directoryWorkQueue = Mutex<DirectoryWorkQueue?>(nil)
    private let computeBundleSizes: Bool
    private let deferTreeMaterialization: Bool
    let filesystem: FilesystemProvider

    public init(
        filesystem: FilesystemProvider = RealFilesystemProvider(),
        computeBundleSizes: Bool = ProcessInfo.processInfo.environment["DIRWIZ_SKIP_BUNDLE_SIZES"] != "1",
        deferTreeMaterialization: Bool = ProcessInfo.processInfo.environment["DIRWIZ_DEFER_TREE"] != "0"
    ) {
        self.filesystem = filesystem
        self.computeBundleSizes = computeBundleSizes
        self.deferTreeMaterialization = deferTreeMaterialization
    }

    /// Cancel an in-progress scan. Safe to call from any thread.
    /// Immediately drops queued-but-not-started operations.
    public func cancel() {
        cancelState.withLock { $0 = true }
        directoryWorkQueue.withLock { $0?.cancel() }
    }

    private var isCancelled: Bool {
        cancelState.withLock { $0 }
    }

    // MARK: - Public API

    /// Resolve opaque bundle leaf sizes after a fast scan that skipped inline bundle sizing.
    ///
    /// The initial scanner pass can treat bundles as zero-sized opaque leaves to make the
    /// tree usable sooner. This method walks only those bundle leaves, computes their
    /// recursive sizes, then applies exact deltas to the tree's ancestor totals.
    public func resolveDeferredBundleSizes(in tree: FileTree) async -> BundleSizeResolutionReport {
        let workItems = tree.bundleSizeCandidates()

        guard !workItems.isEmpty else {
            return BundleSizeResolutionReport(
                bundlesFound: 0,
                bundlesResolved: 0,
                totalFileSize: 0,
                totalAllocatedSize: 0,
                wasCancelled: isCancelled || Task.isCancelled
            )
        }

        struct ResolutionTotals: Sendable {
            var resolved = 0
            var fileSize: UInt64 = 0
            var allocatedSize: UInt64 = 0
        }

        let nextWorkIndex = Mutex(0)
        let totals = Mutex(ResolutionTotals())
        let defaultWorkerCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        let workerCount = ProcessInfo.processInfo.environment["DIRWIZ_BUNDLE_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) }
            ?? defaultWorkerCount

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(workerCount, workItems.count) {
                group.addTask {
                    while !self.isCancelled && !Task.isCancelled {
                        let itemIndex = nextWorkIndex.withLock { cursor -> Int? in
                            guard cursor < workItems.count else { return nil }
                            defer { cursor += 1 }
                            return cursor
                        }
                        guard let itemIndex else { return }

                        let item = workItems[itemIndex]
                        let (fileSize, allocatedSize) = self.filesystem.computeBundleSize(
                            path: item.path,
                            isCancelled: { self.isCancelled || Task.isCancelled }
                        )
                        guard !self.isCancelled && !Task.isCancelled else { return }

                        let didApply = tree.setNodeSizeAndPropagate(
                            at: item.index,
                            fileSize: fileSize,
                            allocatedSize: allocatedSize,
                            expectedDevice: item.device,
                            expectedInode: item.inode
                        )
                        guard didApply else { continue }

                        totals.withLock { stats in
                            stats.resolved += 1
                            let fileResult = stats.fileSize.addingReportingOverflow(fileSize)
                            stats.fileSize = fileResult.overflow ? UInt64.max : fileResult.partialValue
                            let allocatedResult = stats.allocatedSize.addingReportingOverflow(allocatedSize)
                            stats.allocatedSize = allocatedResult.overflow ? UInt64.max : allocatedResult.partialValue
                        }
                    }
                }
            }
        }

        let finalTotals = totals.withLock { $0 }
        return BundleSizeResolutionReport(
            bundlesFound: workItems.count,
            bundlesResolved: finalTotals.resolved,
            totalFileSize: finalTotals.fileSize,
            totalAllocatedSize: finalTotals.allocatedSize,
            wasCancelled: isCancelled || Task.isCancelled
        )
    }

    /// Re-enumerate the given directories into `tree`, replacing each one's descendants.
    /// Paths are absolute, expected under tree's root.
    ///
    /// Two phases per batch (plan 042), preserving 028's resolve-before-apply discipline:
    /// - **Phase A** (`stageChangedRoots`, parallel, I/O-bound): every collapsed root is
    ///   resolved once against the tree's shape at the START of this call, then enumerated
    ///   CONCURRENTLY (bounded to the same worker count cold scan uses) into its own small,
    ///   detached staging `FileTree` — nothing here touches the shared `tree` yet. This is
    ///   the fix for the reported incident: a serial per-root loop re-walking a large
    ///   fraction of the disk single-threaded took minutes where cold (fully parallel)
    ///   took ~20s.
    /// - **Phase B** (`applyStagedRoots`, serial, memory-bound): each staged result is
    ///   spliced in one at a time, re-resolving its path against `tree` FRESH immediately
    ///   before splicing — an earlier splice in this same loop may have compacted and
    ///   renumbered every index (`removeChildren`'s contract). Safe to resolve every root
    ///   ONCE up front in Phase A because `rescannedRoots` are outermost/disjoint
    ///   (`PathCollapse.outermostRoots`): applying one root's splice can never change
    ///   whether an unrelated, non-nested root's path still resolves the same way.
    ///
    /// Resolution runs entirely against path strings before any mutation begins — never
    /// holds a tree index across a splice, since indices are garbage after any mutation
    /// that compacts the array (same discipline as `TreeActions.batchTrash(paths:tree:)`).
    ///
    /// Cancellation: `isCancelled` (this scanner's own flag, flipped by `cancel()`) is the
    /// primary, coherent signal checked in both phases — NOT `Task.isCancelled`, which
    /// stays false unless the surrounding `Task` itself is structurally cancelled (a stale
    /// check 040 flagged: `cancel()` alone never trips it). `Task.isCancelled` is still
    /// honored inside Phase A's child tasks as a secondary signal, since those are real
    /// `Task`s structured cancellation can reach directly. Either way a cancelled rescan
    /// leaves `tree` valid — whatever finished applying stays applied, the rest is
    /// untouched — and `SubtreeRescanReport.wasCancelled` says so honestly.
    public func rescanSubtrees(
        _ changedDirectories: [String],
        tree: FileTree,
        progress: ScanProgress
    ) async -> SubtreeRescanReport {
        // A scanner instance can be reused after cancel(); reset so a stale cancellation
        // from an earlier scan() call doesn't silently no-op this rescan.
        cancelState.withLock { $0 = false }

        var unresolvedPaths: [String] = []
        var resolvedPaths: [String] = []
        for changedPath in changedDirectories {
            guard let resolved = resolveRescanTarget(changedPath, tree: tree) else {
                unresolvedPaths.append(changedPath)
                continue
            }
            resolvedPaths.append(resolved)
        }

        let rescannedRoots = PathCollapse.outermostRoots(resolvedPaths)

        // One instance shared across every target in this batch — matches cold scan's
        // single firmlink/hardlink guard for the whole operation, not one per target. Its
        // internal Mutex makes sharing it across Phase A's concurrent tasks safe.
        let visited = VisitedDirectories()

        let plans = planRescanTargets(rescannedRoots, tree: tree)
        let staged = await stageChangedRoots(plans, progress: progress, visited: visited)
        applyStagedRoots(rescannedRoots, staged: staged, tree: tree, progress: progress)

        tree.recomputeAggregates()

        return SubtreeRescanReport(
            requestedPaths: changedDirectories,
            rescannedRoots: rescannedRoots,
            unresolvedPaths: unresolvedPaths,
            wasCancelled: isCancelled
        )
    }

    /// One collapsed root's batch-start shape: just enough to decide, up front, whether
    /// Phase A should enumerate it as a directory or compute it as an opaque bundle leaf.
    private struct RootPlan {
        let targetPath: String
        let isBundle: Bool
    }

    /// What Phase A produced for one root, keyed by path in `stageChangedRoots`'s result —
    /// never keyed by index, since indices from the batch-start snapshot are meaningless
    /// once Phase B starts splicing.
    private enum StageResult: Sendable {
        case directory(staging: FileTree)
        case bundle(fileSize: UInt64, allocatedSize: UInt64)
    }

    /// Resolves every collapsed root's current shape ONCE, against the tree as it stands
    /// at the very start of this batch — before any splicing happens. See
    /// `rescanSubtrees`'s doc comment for why this one-time-up-front resolution is safe.
    private func planRescanTargets(_ rescannedRoots: [String], tree: FileTree) -> [RootPlan] {
        let snapshot = tree.pathBuildingSnapshot()
        var plans: [RootPlan] = []
        plans.reserveCapacity(rescannedRoots.count)
        for targetPath in rescannedRoots {
            guard let components = Self.relativeComponents(of: targetPath, rootPath: snapshot.rootPath),
                  let targetIndex = FileTree.descendPath(components, nodes: snapshot.nodes, stringPool: snapshot.stringPool) else {
                continue
            }
            let i = Int(targetIndex)
            guard i < snapshot.nodes.count else { continue }
            plans.append(RootPlan(targetPath: targetPath, isBundle: snapshot.nodes[i].isBundle))
        }
        return plans
    }

    /// Phase A: enumerate every plan's on-disk subtree (or compute its bundle size)
    /// concurrently, bounded to the same worker-count knob cold scan uses
    /// (`DIRWIZ_SCAN_WORKERS`). Every directory plan's enumeration work — its root path
    /// AND every subdirectory discovered under it — feeds into ONE shared
    /// `RescanWorkQueue` drained by that many workers, rather than giving each root its
    /// own fixed slice of the pool: a single directory's own entries can't be split
    /// across workers (`getattrlistbulk` reads one handle's entries as one sequential
    /// operation), so across-roots-only parallelism helps when there are many
    /// small-to-medium roots but does nothing extra for the reported incident's actual
    /// shape — ONE dominant root sitting high in the tree. Sharing one queue means idle
    /// workers (roots with nothing left) naturally flow into whichever root still has
    /// work, with no size estimate needed up front. Nothing here touches the shared
    /// `tree`: each directory plan enumerates into its OWN small, detached staging
    /// `FileTree` that `applyStagedRoots` later splices in via `FileTree.installSubtree`.
    private func stageChangedRoots(
        _ plans: [RootPlan],
        progress: ScanProgress,
        visited: VisitedDirectories
    ) async -> [String: StageResult] {
        guard !plans.isEmpty else { return [:] }

        let directoryPlans = plans.filter { !$0.isBundle }
        let bundlePlans = plans.filter { $0.isBundle }

        var stagingByPath: [String: FileTree] = [:]
        stagingByPath.reserveCapacity(directoryPlans.count)
        let sharedQueue = RescanWorkQueue()
        for plan in directoryPlans {
            // Mark each root itself visited before seeding the queue, same as the cold
            // scan marks its root and the old single-consumer drain did — so a firmlink
            // loop can't immediately re-enter a subtree that's already being enumerated.
            if let di = filesystem.deviceAndInode(forPath: plan.targetPath) {
                _ = visited.insert(dev: di.device, inode: di.inode)
            }
            // A larger hint than a "typically small" changed root needs matters
            // specifically for the incident's shape: an undersized reservation means a
            // dominant root's staging tree hits Array's doubling reallocations while
            // MULTIPLE workers are appending into it under its shared lock, serializing
            // everyone on each expensive copy. A few thousand nodes is cheap regardless
            // (a few hundred KB), and a root bigger than that still just grows normally.
            let staging = FileTree(stagingCapacityHint: 4096)
            var placeholderRoot = FileNode()
            placeholderRoot.isDirectory = true
            _ = staging.addNode(placeholderRoot, name: "")
            stagingByPath[plan.targetPath] = staging
            sharedQueue.enqueue(RescanWorkItem(path: plan.targetPath, parentIndex: 0, rootPath: plan.targetPath, staging: staging))
        }

        let tracker = RootCompletionTracker(rootPaths: plans.map(\.targetPath))
        let rootsCompleted = Mutex(0)
        let totalRoots = plans.count
        // Which directory roots actually got AT LEAST one item processed (as opposed to
        // cancelled before their own queue entry was ever dequeued). An untouched root's
        // staging tree is just the placeholder with no children — installing that would
        // wrongly wipe out the target's real, pre-existing children rather than leaving
        // them alone, so `applyStagedRoots` must see `nil` (not `.directory`) for it.
        let touchedRoots = Mutex(Set<String>())

        // Reports one more root done, whichever kind it was — thread-safe from any
        // context, matching cold scan's own `maybeUpdateProgress` (`updateCurrentPath`
        // is the thread-safe hot-counter write; `publishCounters()` must run on
        // MainActor, so it's dispatched fire-and-forget rather than awaited here).
        @Sendable func reportRootDone() {
            let completedSnapshot = rootsCompleted.withLock { count -> Int in
                count += 1
                return count
            }
            progress.updateCurrentPath("Scanning changed folders (\(completedSnapshot) of \(totalRoots))…")
            Task { await MainActor.run { progress.publishCounters() } }
        }

        let workerCount = min(Self.defaultRescanWorkerCount(), max(1, directoryPlans.count))
        var results: [String: StageResult] = [:]
        results.reserveCapacity(plans.count)

        await withTaskGroup(of: (String, StageResult)?.self) { group in
            // Bundle plans: one Task each, no further internal parallelism possible —
            // computing a bundle's size is a single recursive walk, not splittable.
            for plan in bundlePlans {
                group.addTask {
                    guard !Task.isCancelled, !self.isCancelled else { return nil }
                    let (fileSize, allocatedSize) = self.filesystem.computeBundleSize(
                        path: plan.targetPath,
                        isCancelled: { Task.isCancelled || self.isCancelled }
                    )
                    reportRootDone()
                    return (plan.targetPath, .bundle(fileSize: fileSize, allocatedSize: allocatedSize))
                }
            }

            // Directory plans: bridge to a GCD-backed multi-worker drain of the shared
            // queue — plain OS threads (like cold scan's own worker pool), not Swift
            // Tasks, since these loops legitimately block on `RescanWorkQueue.next()`
            // while other workers still have work; blocking a Swift Task body that way
            // risks starving the cooperative thread pool cold scan and everything else
            // shares.
            if !directoryPlans.isEmpty {
                group.addTask {
                    let rawFilesystemForScan = self.filesystem as? RealFilesystemProvider
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let dispatchGroup = DispatchGroup()
                        for _ in 0..<workerCount {
                            dispatchGroup.enter()
                            DispatchQueue.global(qos: .userInitiated).async {
                                let rawBuffer = rawFilesystemForScan.map { _ in
                                    UnsafeMutableRawPointer.allocate(
                                        byteCount: RealFilesystemProvider.directoryBufferSize,
                                        alignment: 16
                                    )
                                }
                                var rawScratch = RawScanScratch()
                                var rawArena = RawScanArena()
                                defer { rawBuffer?.deallocate() }

                                while let item = sharedQueue.next() {
                                    if !self.isCancelled {
                                        touchedRoots.withLock { _ = $0.insert(item.rootPath) }
                                        self.scanDirectory(
                                            dirPath: item.path,
                                            parentIndex: item.parentIndex,
                                            tree: item.staging,
                                            progress: progress,
                                            visited: visited,
                                            enqueue: { path, parentIndex in
                                                tracker.itemEnqueued(forRoot: item.rootPath)
                                                sharedQueue.enqueue(RescanWorkItem(
                                                    path: path, parentIndex: parentIndex,
                                                    rootPath: item.rootPath, staging: item.staging
                                                ))
                                            },
                                            maybeUpdateProgress: { _ in },
                                            rawFilesystem: rawFilesystemForScan,
                                            rawBuffer: rawBuffer,
                                            rawScratch: &rawScratch,
                                            deferredBuilder: nil,
                                            rawArena: &rawArena
                                        )
                                    }
                                    sharedQueue.complete()
                                    if tracker.itemCompleted(forRoot: item.rootPath) {
                                        reportRootDone()
                                    }
                                }
                                dispatchGroup.leave()
                            }
                        }
                        dispatchGroup.notify(queue: .global(qos: .userInitiated)) {
                            continuation.resume()
                        }
                    }
                    return nil
                }
            }

            for await outcome in group {
                if let (targetPath, result) = outcome {
                    results[targetPath] = result
                }
            }
        }

        // Every directory plan's staging tree gets installed here — none of them flow
        // through the task group's return value (only bundle plans do, above), since
        // `stagingByPath` already has a live reference to each one that workers wrote
        // into directly. Skip any root that never got touched (cancelled before its own
        // queue entry was ever dequeued): its staging tree is just the untouched
        // placeholder, and installing that would wipe out the target's real children —
        // leaving it out of `results` entirely makes `applyStagedRoots` see `nil` and
        // correctly leave that root untouched instead.
        let touched = touchedRoots.withLock { $0 }
        for (targetPath, staging) in stagingByPath where results[targetPath] == nil && touched.contains(targetPath) {
            results[targetPath] = .directory(staging: staging)
        }

        return results
    }

    /// Phase B: apply each staged result in `rescannedRoots` order, re-resolving its path
    /// against `tree` fresh immediately before splicing — see `rescanSubtrees`'s doc
    /// comment for why an earlier splice in this same loop can invalidate a later target's
    /// index but never its path.
    private func applyStagedRoots(
        _ rescannedRoots: [String],
        staged: [String: StageResult],
        tree: FileTree,
        progress: ScanProgress
    ) {
        let total = rescannedRoots.count
        var completed = 0
        for targetPath in rescannedRoots {
            guard !isCancelled, !Task.isCancelled else { break }
            completed += 1

            // Resolved in its own function so the snapshot's `nodes`/`stringPool`
            // references (a full-tree COW handle) are provably released before this
            // iteration mutates the tree — holding them any longer would force
            // `removeChildren`/`installSubtree` to copy the entire array on every single
            // root instead of appending in place (measured: this was Phase B's actual
            // bottleneck on a large batch, not the per-node splice work itself).
            guard let targetIndex = Self.resolveCurrentIndex(of: targetPath, tree: tree),
                  let targetNode = tree.node(at: targetIndex) else {
                continue
            }

            switch staged[targetPath] {
            case .bundle(let fileSize, let allocatedSize):
                tree.setNodeSizeAndPropagate(
                    at: targetIndex,
                    fileSize: fileSize,
                    allocatedSize: allocatedSize,
                    expectedDevice: targetNode.device,
                    expectedInode: targetNode.inode
                )
            case .directory(let staging):
                tree.removeChildren(of: targetIndex)
                tree.installSubtree(staging, at: targetIndex)
            case nil:
                // Cancelled before Phase A ever got to this root — nothing staged, so
                // there's nothing trustworthy to apply. Leave it untouched rather than
                // guessing; the next rescan will pick it up again.
                continue
            }

            // A changed dir's mtime is user-visible in the table.
            if let mtime = Self.modifiedDate(atPath: targetPath) {
                tree.updateNode(at: targetIndex) { $0.modifiedDate = mtime }
            }

            // Thread-safe hot-counter write (see `stageChangedRoots`'s matching comment) —
            // setting `progress.currentPath` directly here would just get clobbered by
            // `publishCounters()`'s own `currentPath = snapshot.path` line.
            progress.updateCurrentPath("Refreshing changed folders (\(completed) of \(total))…")
            Task { await MainActor.run {
                progress.publishCounters()
            } }
        }
    }

    /// Re-resolves `targetPath` to its CURRENT index in `tree` by path, isolated in its
    /// own function so the `pathBuildingSnapshot()` it takes (a COW handle on the WHOLE
    /// tree's nodes array and string pool) is provably released on return rather than
    /// staying alive for the rest of the caller's loop body. `applyStagedRoots` calls
    /// this immediately before each splice; if the snapshot outlived the splice, the
    /// splice's own mutation (`removeChildren`/`installSubtree`) would see a
    /// reference count > 1 and copy the ENTIRE array before appending instead of growing
    /// it in place — on a large batch this dwarfed the actual per-node splice cost.
    private static func resolveCurrentIndex(of targetPath: String, tree: FileTree) -> UInt32? {
        let snapshot = tree.pathBuildingSnapshot()
        guard let components = Self.relativeComponents(of: targetPath, rootPath: snapshot.rootPath) else {
            return nil
        }
        return FileTree.descendPath(components, nodes: snapshot.nodes, stringPool: snapshot.stringPool)
    }

    /// Same worker-count sizing cold scan uses for its `DirectoryWorkQueue` pool
    /// (`DIRWIZ_SCAN_WORKERS`, defaulting to 4–6 based on core count) — reused here so
    /// Phase A's across-roots concurrency is governed by the one existing tunable knob
    /// rather than a second, uncoordinated one.
    private static func defaultRescanWorkerCount() -> Int {
        let defaultWorkerCount = min(6, max(4, ProcessInfo.processInfo.activeProcessorCount))
        return ProcessInfo.processInfo.environment["DIRWIZ_SCAN_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) }
            ?? defaultWorkerCount
    }

    /// Resolve one changed-directory path to the deepest ancestor that both still exists
    /// on disk and already resolves inside `tree` — handles deleted dirs, brand-new dirs
    /// (whose parent resolves instead), and renames with a single rule. Root is always a
    /// valid last resort. Returns nil only when `changedPath` isn't under the tree's root.
    private func resolveRescanTarget(_ changedPath: String, tree: FileTree) -> String? {
        let snapshot = tree.pathBuildingSnapshot()
        guard !snapshot.nodes.isEmpty else { return nil }
        let rootPath = snapshot.rootPath

        guard let components = Self.relativeComponents(of: changedPath, rootPath: rootPath) else {
            return nil
        }

        var depth = components.count
        while depth > 0 {
            let candidateComponents = Array(components[0..<depth])
            let candidatePath = Self.absolutePath(rootPath: rootPath, components: candidateComponents)
            if filesystem.deviceAndInode(forPath: candidatePath) != nil,
               FileTree.descendPath(candidateComponents, nodes: snapshot.nodes, stringPool: snapshot.stringPool) != nil {
                return candidatePath
            }
            depth -= 1
        }
        return Self.absolutePath(rootPath: rootPath, components: [])
    }

    /// Split `path` into components relative to `rootPath`, or nil if `path` is neither
    /// `rootPath` itself nor a boundary-respecting descendant of it (e.g. rejects
    /// "/root-2" against root "/root"). Module-internal (not `private`) rather than
    /// duplicated: `WarmStartPlanner.estimatedPatchItemCount` (WarmStart.swift, plan 042)
    /// needs the identical path-splitting logic to resolve a changed root against the
    /// CACHED tree before `FileScanner` itself is even involved.
    static func relativeComponents(of path: String, rootPath: String) -> [String]? {
        let normalizedPath = normalizePath(path)
        let normalizedRoot = normalizePath(rootPath)
        if normalizedPath == normalizedRoot { return [] }
        let boundaryPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedPath.hasPrefix(boundaryPrefix) else { return nil }
        let relative = String(normalizedPath.dropFirst(boundaryPrefix.count))
        guard !relative.isEmpty else { return [] }
        return relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func absolutePath(rootPath: String, components: [String]) -> String {
        let normalizedRoot = normalizePath(rootPath)
        guard !components.isEmpty else { return normalizedRoot }
        let suffix = components.joined(separator: "/")
        if normalizedRoot == "/" { return "/" + suffix }
        return normalizedRoot + "/" + suffix
    }

    /// One-off `lstat` for the mtime refresh after a splice. Bypasses `FilesystemProvider`
    /// (which has no modification-time accessor and is out of scope to extend here) — this
    /// only degrades gracefully on a mocked provider in tests, since real subtree rescans
    /// always run against `RealFilesystemProvider`.
    private static func modifiedDate(atPath path: String) -> UInt32? {
        var s = stat()
        guard lstat(path, &s) == 0 else { return nil }
        return UInt32(clamping: max(0, Int(s.st_mtimespec.tv_sec)))
    }

    /// Scan the filesystem at `path`, returning the tree.
    /// The tree is populated incrementally — assign it to your UI state before awaiting
    /// this method if you want live updates.
    /// Pass the returned FileTree to the UI immediately; it's populated in-place during scan.
    public func scan(path: String, progress: ScanProgress, tree: FileTree) async {
        // Reset cancellation so a scanner instance can be reused after cancel().
        cancelState.withLock { $0 = false }

        // Estimate total items using inode counts (blocking I/O, done off main thread).
        var estimatedItems = 0
        if let sf = filesystem.volumeStats(forPath: path) {
            let normalizedPath = Self.normalizePath(path)
            let normalizedMountPoint = Self.normalizePath(sf.mountPoint)
            if normalizedPath == normalizedMountPoint {
                // Int64(clamping:) saturates at Int64.max instead of trapping on UInt64 values
                // that exceed Int64.max (e.g. a mock or corrupted statfs result with UInt64.max).
                let usedInodes = max(0, Int64(clamping: sf.totalFiles) - Int64(clamping: sf.freeFiles))
                if usedInodes > 0 {
                    estimatedItems = Int(clamping: usedInodes)
                }

                // Scanning "/" follows firmlinks into the Data volume; include its inode usage too.
                if normalizedPath == "/" {
                    if let dataSF = filesystem.volumeStats(forPath: "/System/Volumes/Data") {
                        let dataUsedInodes = max(0, Int64(clamping: dataSF.totalFiles) - Int64(clamping: dataSF.freeFiles))
                        if dataUsedInodes > 0 {
                            estimatedItems += Int(clamping: dataUsedInodes)
                        }
                    }
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
        let displayRootName = rootName.isEmpty ? path : rootName

        // Visited directory tracker (prevents firmlink/hardlink double-counting)
        let visited = VisitedDirectories()

        // Mark root as visited
        if let di = filesystem.deviceAndInode(forPath: path) {
            rootNode.device = di.device
            rootNode.inode = di.inode
            _ = visited.insert(dev: di.device, inode: di.inode)
        }
        _ = tree.addNode(rootNode, name: displayRootName)

        // Determine network-FS status for queue concurrency.
        let isNetworkFS: Bool
        if let sf = filesystem.volumeStats(forPath: path) {
            isNetworkFS = sf.filesystemType == "smbfs"
                || sf.filesystemType == "nfs"
                || sf.filesystemType == "afpfs"
                || sf.filesystemType == "webdavfs"
        } else {
            isNetworkFS = false
        }

        // Fixed worker pool for parallel directory scanning. A shared queue avoids
        // creating one Operation object per directory on large trees.
        let workQueue = DirectoryWorkQueue()
        directoryWorkQueue.withLock { $0 = workQueue }
        defer { directoryWorkQueue.withLock { $0 = nil } }
        let defaultWorkerCount = isNetworkFS
            ? 4
            : min(6, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let workerCount = ProcessInfo.processInfo.environment["DIRWIZ_SCAN_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) }
            ?? defaultWorkerCount
        let rawFilesystemForScan = filesystem as? RealFilesystemProvider
        let deferredBuilder = rawFilesystemForScan != nil && deferTreeMaterialization
            ? DeferredTreeBuilder()
            : nil
        let completedArenas = Mutex<[FileTreeArena]>([])

        // Throttle progress updates
        let progressThrottle = Mutex(CFAbsoluteTime(0))

        @Sendable
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
                Task { await MainActor.run {
                    progress.elapsedTime = elapsed
                    progress.publishCounters()
                } }
            }
        }

        @Sendable
        func enqueueDirectory(dirPath: String, parentIndex: UInt32) {
            guard !self.isCancelled else { return }
            workQueue.enqueue(path: dirPath, parentIndex: parentIndex)
        }

        enqueueDirectory(dirPath: path, parentIndex: 0)

        // Wait for the fixed worker pool to drain all queued directory work.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<workerCount {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let rawFilesystem = rawFilesystemForScan
                    let rawBuffer = rawFilesystem.map { _ in
                        UnsafeMutableRawPointer.allocate(
                            byteCount: RealFilesystemProvider.directoryBufferSize,
                            alignment: 16
                        )
                    }
                    var rawScratch = RawScanScratch()
                    var rawArena = RawScanArena()
                    defer { rawBuffer?.deallocate() }

                    while let item = workQueue.next() {
                        if self.isCancelled {
                            workQueue.complete()
                            continue
                        }
                        self.scanDirectory(
                            dirPath: item.path,
                            parentIndex: item.parentIndex,
                            tree: tree,
                            progress: progress,
                            visited: visited,
                            enqueue: enqueueDirectory,
                            maybeUpdateProgress: maybeUpdateProgress,
                            rawFilesystem: rawFilesystem,
                            rawBuffer: rawBuffer,
                            rawScratch: &rawScratch,
                            deferredBuilder: deferredBuilder,
                            rawArena: &rawArena
                        )
                        workQueue.complete()
                    }
                    if deferredBuilder != nil, !rawArena.isEmpty {
                        let arena = rawArena.export()
                        completedArenas.withLock { $0.append(arena) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }

        if let deferredBuilder {
            let snapshot = deferredBuilder.snapshot()
            let arenas = completedArenas.withLock { $0 }
            tree.replaceContents(
                rootNode: rootNode,
                rootName: displayRootName,
                childRanges: snapshot.childRanges,
                arenas: arenas,
                totalNodeCount: snapshot.totalNodeCount
            )
        }

        // Propagate sizes bottom-up in a single O(n) pass.
        // During scanning, each node stores only its own direct size (files) or bundle size.
        // This replaces per-directory accumulateSize() calls that walked the parent chain
        // under lock, causing heavy contention with 32 concurrent threads.
        tree.propagateSizes()

        // Finalize progress — publish final counters before marking complete
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let wasCancelled = isCancelled
        await MainActor.run {
            progress.publishCounters(forceLayoutRevision: true)
            progress.elapsedTime = totalElapsed
            progress.isScanning = false
            progress.scanComplete = true
            if wasCancelled {
                progress.isCancelled = true
            }
        }
    }

    // MARK: - Directory Scan (single directory)

    private func scanDirectory(
        dirPath: String,
        parentIndex: UInt32,
        tree: FileTree,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        maybeUpdateProgress: @escaping @Sendable (String) -> Void,
        rawFilesystem: RealFilesystemProvider? = nil,
        rawBuffer: UnsafeMutableRawPointer? = nil,
        rawScratch: inout RawScanScratch,
        deferredBuilder: DeferredTreeBuilder? = nil,
        rawArena: inout RawScanArena
    ) {
        guard !isCancelled else { return }
        maybeUpdateProgress(dirPath)

        if let realFilesystem = rawFilesystem ?? (filesystem as? RealFilesystemProvider) {
            if let deferredBuilder {
                scanDirectoryRawDeferred(
                    filesystem: realFilesystem,
                    dirPath: dirPath,
                    parentIndex: parentIndex,
                    progress: progress,
                    visited: visited,
                    enqueue: enqueue,
                    rawBuffer: rawBuffer,
                    scratch: &rawScratch,
                    builder: deferredBuilder,
                    arena: &rawArena
                )
            } else {
                scanDirectoryRaw(
                    filesystem: realFilesystem,
                    dirPath: dirPath,
                    parentIndex: parentIndex,
                    tree: tree,
                    progress: progress,
                    visited: visited,
                    enqueue: enqueue,
                    rawBuffer: rawBuffer,
                    scratch: &rawScratch
                )
            }
            return
        }

        // Collect all children in this directory
        var children: [(node: FileNode, name: String)] = []
        var subdirs: [(name: String, childIndex: Int, dev: Int32, inode: UInt64)] = []
        var bundleDirs: [(name: String, childIndex: Int)] = []
        children.reserveCapacity(32)
        subdirs.reserveCapacity(8)
        bundleDirs.reserveCapacity(2)

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        // false means open() failed (permission denied, etc.) — matches original behaviour.
        let opened = filesystem.forEachDirectoryEntry(path: dirPath) { rawEntry in
            guard !isCancelled else { return false }

            let entryName = rawEntry.name
            guard !entryName.isEmpty, entryName != ".", entryName != ".." else { return true }

            // Skip symlinks entirely — following them causes double-counting and potential
            // infinite loops. See original FileScanner for detailed rationale.
            guard !rawEntry.isSymlink else { return true }

            let isDir = rawEntry.isDirectory
            let modDate = rawEntry.modifiedDate

            var dataLength: UInt64 = 0
            var allocSize: UInt64 = 0
            if !isDir {
                dataLength = rawEntry.fileSize
                allocSize  = rawEntry.allocatedSize
            }

            // Build FileNode
            var node = FileNode()
            node.isDirectory = isDir
            node.fileSize = isDir ? 0 : dataLength
            node.allocatedSize = isDir ? 0 : allocSize
            node.modifiedDate = modDate
            node.device = rawEntry.device
            node.inode = rawEntry.inode
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
                    subdirs.append((name: entryName, childIndex: childLocalIndex,
                                    dev: rawEntry.device, inode: rawEntry.inode))
                }
                dirCount += 1
            } else {
                totalFileSize += dataLength
                totalAllocatedSize += allocSize
                fileCount += 1
            }
            return true
        }

        guard opened else {
            scanLog.warning("Skipped (permission denied): \(dirPath, privacy: .public)")
            progress.incrementSkippedDirectories()
            return
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
        if computeBundleSizes {
            for bundle in bundleDirs {
                guard !isCancelled else { break }
                let bundlePath = appendPathComponent(dirPath, bundle.name)
                let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                    path: bundlePath,
                    isCancelled: { self.isCancelled }
                )
                guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
                let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
                tree.updateNode(at: bundleTreeIndex) { node in
                    node.fileSize = bundleFileSize
                    node.allocatedSize = bundleAllocatedSize
                }
            }
        }

        // Enqueue subdirectories — skip already-visited (dev, inode) pairs (firmlinks, hardlinks)
        for subdir in subdirs {
            guard !isCancelled else { break }
            guard visited.insert(dev: subdir.dev, inode: subdir.inode) else {
                continue // Already visited this directory via another path (firmlink)
            }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
            let subdirPath = appendPathComponent(dirPath, subdir.name)
            enqueue(subdirPath, childTreeIndex)
        }
    }

    /// Decode a name from a scratch/arena-local name pool by byte offset/length.
    /// Shared by both raw materialization strategies below.
    private static func nameString(in namePool: Data, offset: Int, length: Int) -> String {
        namePool.withUnsafeBytes { rawPool in
            let pool = rawPool.bindMemory(to: UInt8.self)
            guard let base = pool.baseAddress, offset >= 0, offset < pool.count else { return "" }
            let clampedLength = min(length, pool.count - offset)
            return String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset), count: clampedLength), as: UTF8.self)
        }
    }

    /// Shared core for both raw-buffer scan strategies (immediate and deferred
    /// materialization): reads one directory's entries via `forEachRawDirectoryEntry`,
    /// classifies each into file/dir/bundle with size + counter accounting, then hands
    /// the populated scratch buffer to `materialize` — the only variation point.
    ///
    /// `materialize` performs bundle-size computation and writes the children into
    /// their destination (tree or deferred arena) in whichever order that destination
    /// requires (immediate mode publishes to the tree first so the UI sees the entry
    /// sooner, then patches bundle sizes in place; deferred mode has no tree node to
    /// patch later, so it must bake bundle sizes into the scratch children before they
    /// are copied into the arena). It returns the first child index, which this shared
    /// core then uses to enqueue subdirectories — identical in both strategies.
    private func processRawDirectory(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch,
        materialize: (inout RawScanScratch, UInt32) -> UInt32
    ) {
        scratch.reset()

        var totalFileSize: UInt64 = 0
        var totalAllocatedSize: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

        let opened: Bool
        if let rawBuffer {
            opened = filesystem.forEachRawDirectoryEntry(
                path: dirPath,
                buffer: rawBuffer,
                bufferSize: RealFilesystemProvider.directoryBufferSize,
                { rawEntry in processRawEntry(rawEntry) }
            )
        } else {
            opened = filesystem.forEachRawDirectoryEntry(path: dirPath) { rawEntry in
                processRawEntry(rawEntry)
            }
        }

        func processRawEntry(_ rawEntry: RawDirectoryEntry) -> Bool {
            guard !isCancelled else { return false }
            let isDir = rawEntry.isDirectory

            var node = FileNode()
            node.isDirectory = isDir
            node.fileSize = isDir ? 0 : rawEntry.fileSize
            node.allocatedSize = isDir ? 0 : rawEntry.allocatedSize
            node.modifiedDate = rawEntry.modifiedDate
            node.device = rawEntry.device
            node.inode = rawEntry.inode
            if !isDir {
                node.extensionHash = extensionHash(rawEntry.nameBytes)
            }

            let isBundle = isDir && isBundleName(rawEntry.nameBytes)
            if isBundle {
                node.isBundle = true
            }

            let nameOffset = scratch.namePool.count
            let nameLength = rawEntry.nameBytes.count
            if let base = rawEntry.nameBytes.baseAddress {
                scratch.namePool.append(contentsOf: UnsafeBufferPointer(start: base, count: nameLength))
            }

            let childLocalIndex = scratch.children.count
            scratch.children.append(EncodedFileNode(
                node: node,
                nameOffset: nameOffset,
                nameLength: nameLength
            ))

            if isDir {
                if isBundle {
                    scratch.bundleDirs.append((nameOffset: nameOffset, nameLength: nameLength, childIndex: childLocalIndex))
                } else {
                    scratch.subdirs.append((
                        nameOffset: nameOffset,
                        nameLength: nameLength,
                        childIndex: childLocalIndex,
                        dev: rawEntry.device,
                        inode: rawEntry.inode
                    ))
                }
                dirCount += 1
            } else {
                totalFileSize += rawEntry.fileSize
                totalAllocatedSize += rawEntry.allocatedSize
                fileCount += 1
            }
            return true
        }

        guard opened else {
            scanLog.warning("Skipped (permission denied): \(dirPath, privacy: .public)")
            progress.incrementSkippedDirectories()
            return
        }

        if fileCount > 0 {
            progress.incrementFiles(count: fileCount, size: totalFileSize, allocatedSize: totalAllocatedSize)
        }
        if dirCount > 0 {
            progress.incrementDirectories(count: dirCount)
        }

        guard !scratch.children.isEmpty else { return }

        let firstChildIndex = materialize(&scratch, parentIndex)

        for subdir in scratch.subdirs {
            guard !isCancelled else { break }
            guard visited.insert(dev: subdir.dev, inode: subdir.inode) else {
                continue
            }
            let subdirName = Self.nameString(in: scratch.namePool, offset: subdir.nameOffset, length: subdir.nameLength)
            guard !subdirName.isEmpty else { continue }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
            let subdirPath = appendPathComponent(dirPath, subdirName)
            enqueue(subdirPath, childTreeIndex)
        }
    }

    private func scanDirectoryRaw(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        tree: FileTree,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch
    ) {
        processRawDirectory(
            filesystem: filesystem,
            dirPath: dirPath,
            parentIndex: parentIndex,
            progress: progress,
            visited: visited,
            enqueue: enqueue,
            rawBuffer: rawBuffer,
            scratch: &scratch
        ) { scratch, parentIndex in
            // Materialize immediately so the tree is visible to readers as soon as
            // possible, then patch bundle sizes into the already-published node in place.
            let firstChildIndex = tree.addChildren(
                encoded: scratch.children,
                namePool: scratch.namePool,
                parentIndex: parentIndex
            )

            if self.computeBundleSizes {
                for bundle in scratch.bundleDirs {
                    guard !self.isCancelled else { break }
                    let bundleName = Self.nameString(in: scratch.namePool, offset: bundle.nameOffset, length: bundle.nameLength)
                    guard !bundleName.isEmpty else { continue }
                    let bundlePath = appendPathComponent(dirPath, bundleName)
                    let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                        path: bundlePath,
                        isCancelled: { self.isCancelled }
                    )
                    guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
                    let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
                    tree.updateNode(at: bundleTreeIndex) { node in
                        node.fileSize = bundleFileSize
                        node.allocatedSize = bundleAllocatedSize
                    }
                }
            }

            return firstChildIndex
        }
    }

    private func scanDirectoryRawDeferred(
        filesystem: RealFilesystemProvider,
        dirPath: String,
        parentIndex: UInt32,
        progress: ScanProgress,
        visited: VisitedDirectories,
        enqueue: @escaping @Sendable (String, UInt32) -> Void,
        rawBuffer: UnsafeMutableRawPointer?,
        scratch: inout RawScanScratch,
        builder: DeferredTreeBuilder,
        arena: inout RawScanArena
    ) {
        processRawDirectory(
            filesystem: filesystem,
            dirPath: dirPath,
            parentIndex: parentIndex,
            progress: progress,
            visited: visited,
            enqueue: enqueue,
            rawBuffer: rawBuffer,
            scratch: &scratch
        ) { scratch, parentIndex in
            // No tree node exists yet to patch after the fact — bundle sizes must be
            // baked into the scratch children before they are copied into the arena.
            if self.computeBundleSizes {
                for bundle in scratch.bundleDirs {
                    guard !self.isCancelled else { break }
                    let bundleName = Self.nameString(in: scratch.namePool, offset: bundle.nameOffset, length: bundle.nameLength)
                    guard !bundleName.isEmpty else { continue }
                    let bundlePath = appendPathComponent(dirPath, bundleName)
                    let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                        path: bundlePath,
                        isCancelled: { self.isCancelled }
                    )
                    guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
                    scratch.children[bundle.childIndex].node.fileSize = bundleFileSize
                    scratch.children[bundle.childIndex].node.allocatedSize = bundleAllocatedSize
                }
            }

            let firstChildIndex = builder.reserveChildren(parentIndex: parentIndex, count: scratch.children.count)
            arena.append(
                children: scratch.children,
                localNamePool: scratch.namePool,
                firstIndex: firstChildIndex,
                parentIndex: parentIndex
            )
            return firstChildIndex
        }
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path == "/" { return "/" }
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

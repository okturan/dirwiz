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

/// Proper composite key for (dev, inode) pairs - avoids XOR hash collisions.
private struct InodeKey: Hashable, Sendable {
    let dev: Int32
    let inode: UInt64
}

// MARK: - Visited Directory Tracker

/// Thread-safe set tracking visited (dev, inode) pairs to avoid hardlink/mount loops,
/// plus the firmlink duplicate paths that `(dev, inode)` provably cannot catch.
private final class VisitedDirectories: Sendable {
    enum TraversalDecision {
        case traverse
        case mountBoundary
        case alreadyVisited
        case firmlinkDuplicate
    }

    private let seen = Mutex(Set<InodeKey>())

    /// Absolute Data-volume paths already reachable via a firmlink (see `FirmlinkTable`).
    /// Empty when deduplication is off, which reproduces the previous behavior exactly.
    private let firmlinkDuplicates: Set<String>
    private let rootDevice: Int32?
    private let mountTraversalScope: MountTraversalScope

    init(
        rootDevice: Int32? = nil,
        mountTraversalScope: MountTraversalScope = .selectedVolume,
        firmlinkDuplicates: Set<String> = []
    ) {
        self.rootDevice = rootDevice
        self.mountTraversalScope = mountTraversalScope
        self.firmlinkDuplicates = firmlinkDuplicates
    }

    /// Returns true if this is the first time seeing this (dev, inode) pair.
    func insert(dev: Int32, inode: UInt64) -> Bool {
        let key = InodeKey(dev: dev, inode: inode)
        return seen.withLock { $0.insert(key).inserted }
    }

    /// Whether this device is outside an individual scan's known root device. A missing
    /// root device deliberately fails open; combined and diagnostic scopes cross mounts.
    func isMountBoundary(device: Int32) -> Bool {
        guard mountTraversalScope == .selectedVolume, let rootDevice else { return false }
        return device != rootDevice
    }

    /// The single "should I descend into this directory?" gate.
    ///
    /// Checks the firmlink table FIRST and deliberately does not mark the inode visited
    /// when skipping: the `/`-side copy of the same content must stay free to claim it.
    /// Marking it here would trade a double count for a silent omission.
    func traversalDecision(path: String, dev: Int32, inode: UInt64) -> TraversalDecision {
        if !firmlinkDuplicates.isEmpty, firmlinkDuplicates.contains(path) {
            return .firmlinkDuplicate
        }
        // Do not claim the inode when rejecting a mount. A separately encountered eligible
        // path must remain free to traverse it, matching the firmlink skip discipline.
        if isMountBoundary(device: dev) { return .mountBoundary }
        return insert(dev: dev, inode: inode) ? .traverse : .alreadyVisited
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
/// across every changed root instead of one queue per root - a single worker pool that
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
/// progress even though the queue itself has no notion of "root" - many workers may be
/// draining items that all belong to the SAME root, or to different ones, in any order.
/// Seeded with one pending item per root (its own root path); each discovered
/// subdirectory bumps its root's count, each finished item decrements it - the root is
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
    var bundleDirs: [(
        nameOffset: Int,
        nameLength: Int,
        childIndex: Int,
        dev: Int32,
        inode: UInt64
    )] = []

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

/// Low-overhead diagnostics for one `FileScanner.rescanSubtrees` invocation.
///
/// Timings use a monotonic `ContinuousClock`; `totalSeconds` intentionally includes
/// orchestration gaps not assigned to one of the named phases. Node counts distinguish
/// work staged off-tree from nodes actually committed to the destination tree.
public struct SubtreeRescanMetrics: Sendable {
    /// Actual Phase A work attributed to one collapsed rescan root.
    public struct RootStaging: Sendable, Equatable {
        public let path: String
        /// Original `rescanSubtrees` paths whose resolved targets collapsed into `path`,
        /// preserving request order. This keeps cached-plan estimates attributable even
        /// when a new or deleted path has to be rescanned through an existing ancestor.
        public let contributingRequestedPaths: [String]
        /// Directory staging trees include their placeholder/target root. Opaque bundle
        /// results count as one item because Phase A stages the bundle target itself.
        public let actualStagedItemCount: Int

        public init(path: String, actualStagedItemCount: Int) {
            self.path = path
            self.contributingRequestedPaths = [path]
            self.actualStagedItemCount = actualStagedItemCount
        }

        public init(
            path: String,
            contributingRequestedPaths: [String],
            actualStagedItemCount: Int
        ) {
            self.path = path
            self.contributingRequestedPaths = contributingRequestedPaths
            self.actualStagedItemCount = actualStagedItemCount
        }
    }

    public let preflightAndPlanningSeconds: Double
    public let phaseAStagingSeconds: Double
    public let phaseBTargetResolutionSeconds: Double
    public let phaseBStructuralCompactionSeconds: Double
    public let postCommitMetadataSeconds: Double
    public let aggregateRecomputeSeconds: Double
    public let totalSeconds: Double

    public let beforeNodeCount: Int
    /// Nodes in detached directory staging trees, including one placeholder root per
    /// staged directory. Opaque bundle results do not create staging-tree nodes.
    public let stagedNodeCount: Int
    /// Non-placeholder staged nodes actually appended by a committed structural splice.
    public let appendedNodeCount: Int
    /// Old descendants actually removed by a committed structural splice.
    public let removedNodeCount: Int
    public let afterNodeCount: Int

    public let requestedPathCount: Int
    public let rescannedRootCount: Int
    public let plannedRootCount: Int
    public let stagedRootCount: Int
    public let resolvedTargetCount: Int
    public let structurallyReplacedRootCount: Int
    public let appliedRootCount: Int
    /// Phase A results in deterministic `rescannedRoots` order. A root cancelled before
    /// producing any result is omitted rather than reported as an empty staged subtree.
    public let rootStaging: [RootStaging]

    public init(
        preflightAndPlanningSeconds: Double = 0,
        phaseAStagingSeconds: Double = 0,
        phaseBTargetResolutionSeconds: Double = 0,
        phaseBStructuralCompactionSeconds: Double = 0,
        postCommitMetadataSeconds: Double = 0,
        aggregateRecomputeSeconds: Double = 0,
        totalSeconds: Double = 0,
        beforeNodeCount: Int = 0,
        stagedNodeCount: Int = 0,
        appendedNodeCount: Int = 0,
        removedNodeCount: Int = 0,
        afterNodeCount: Int = 0,
        requestedPathCount: Int = 0,
        rescannedRootCount: Int = 0,
        plannedRootCount: Int = 0,
        stagedRootCount: Int = 0,
        resolvedTargetCount: Int = 0,
        structurallyReplacedRootCount: Int = 0,
        appliedRootCount: Int = 0,
        rootStaging: [RootStaging] = []
    ) {
        self.preflightAndPlanningSeconds = preflightAndPlanningSeconds
        self.phaseAStagingSeconds = phaseAStagingSeconds
        self.phaseBTargetResolutionSeconds = phaseBTargetResolutionSeconds
        self.phaseBStructuralCompactionSeconds = phaseBStructuralCompactionSeconds
        self.postCommitMetadataSeconds = postCommitMetadataSeconds
        self.aggregateRecomputeSeconds = aggregateRecomputeSeconds
        self.totalSeconds = totalSeconds
        self.beforeNodeCount = beforeNodeCount
        self.stagedNodeCount = stagedNodeCount
        self.appendedNodeCount = appendedNodeCount
        self.removedNodeCount = removedNodeCount
        self.afterNodeCount = afterNodeCount
        self.requestedPathCount = requestedPathCount
        self.rescannedRootCount = rescannedRootCount
        self.plannedRootCount = plannedRootCount
        self.stagedRootCount = stagedRootCount
        self.resolvedTargetCount = resolvedTargetCount
        self.structurallyReplacedRootCount = structurallyReplacedRootCount
        self.appliedRootCount = appliedRootCount
        self.rootStaging = rootStaging
    }

    public static let zero = SubtreeRescanMetrics()
}

/// Outcome of `FileScanner.rescanSubtrees`.
public struct SubtreeRescanReport: Sendable {
    /// Exact Phase A work exceeded the caller's remaining staged-item budget, so Phase B
    /// was not entered and the destination tree was left untouched.
    public struct StagedItemBudgetExceeded: Equatable, Sendable {
        public let actualStagedItemCount: Int
        public let maximumStagedItemCount: Int

        public init(
            actualStagedItemCount: Int,
            maximumStagedItemCount: Int
        ) {
            self.actualStagedItemCount = actualStagedItemCount
            self.maximumStagedItemCount = maximumStagedItemCount
        }
    }

    public let requestedPaths: [String]
    /// Targets actually spliced, after ancestor-resolution + outermost-dedupe. A
    /// root-level entry here means some requested path couldn't resolve to anything
    /// narrower than the scan root - recorded honestly rather than silently absorbed;
    /// callers with a cold-fallback threshold (e.g. warm start) should treat it as a
    /// signal to prefer a full rescan.
    public let rescannedRoots: [String]
    /// Requested paths that weren't under the tree's root at all.
    public let unresolvedPaths: [String]
    /// True if cancellation (`FileScanner.cancel()`, or the enclosing `Task` itself being
    /// cancelled) was observed at any point during the rescan (plan 042) - some of
    /// `rescannedRoots` may not actually have been applied to the tree yet. The tree is
    /// left structurally valid either way (whatever finished applying stays applied, the
    /// rest is untouched), but callers should treat a cancelled rescan as incomplete
    /// rather than a normal completion - no cache write-back under the new event id, no
    /// "success" summary.
    public let wasCancelled: Bool
    /// Present only when Phase A completed normally but its exact staged-item count was
    /// over the caller's budget. This stays distinct from cancellation and path-resolution
    /// failures so a warm-start caller can reuse its coherent cold-abandonment path.
    public let stagedItemBudgetExceeded: StagedItemBudgetExceeded?
    /// Subset of `rescannedRoots` reconciled IN PLACE at one entry level (file-derived
    /// targets whose level matched the cached children). A root-level entry here is a
    /// successful reconcile, NOT the "couldn't resolve anything narrower" signal that a
    /// root-level entry in `rescannedRoots` alone historically carried - callers with a
    /// root-level cold-fallback rule must exempt these.
    public let shallowRoots: [String]
    public let metrics: SubtreeRescanMetrics

    public init(
        requestedPaths: [String],
        rescannedRoots: [String],
        unresolvedPaths: [String],
        wasCancelled: Bool = false,
        stagedItemBudgetExceeded: StagedItemBudgetExceeded? = nil,
        shallowRoots: [String] = [],
        metrics: SubtreeRescanMetrics = .zero
    ) {
        self.requestedPaths = requestedPaths
        self.rescannedRoots = rescannedRoots
        self.unresolvedPaths = unresolvedPaths
        self.wasCancelled = wasCancelled
        self.stagedItemBudgetExceeded = stagedItemBudgetExceeded
        self.shallowRoots = shallowRoots
        self.metrics = metrics
    }
}

/// Scheduling and cancellation semantics for one subtree-rescan tier.
///
/// The ordinary interactive tier starts a new logical rescan and therefore clears a
/// stale cancellation from any previous use of the scanner. A trailing tier is part of
/// that same logical rescan: it preserves cancellation so a click landing between tiers
/// cannot be erased, and it drains filesystem work at utility QoS.
public struct SubtreeRescanOptions: Equatable, Sendable {
    public enum Priority: Equatable, Sendable {
        case interactive
        case utility
    }

    public let priority: Priority
    public let resetsCancellation: Bool
    /// Exact Phase A ceiling for this invocation. A two-tier warm patch supplies the
    /// remaining portion of one shared budget; ordinary subtree rescans leave it nil.
    public let maximumStagedItemCount: Int?

    public init(
        priority: Priority,
        resetsCancellation: Bool,
        maximumStagedItemCount: Int? = nil
    ) {
        self.priority = priority
        self.resetsCancellation = resetsCancellation
        self.maximumStagedItemCount = maximumStagedItemCount
    }

    public static let interactive = SubtreeRescanOptions(
        priority: .interactive,
        resetsCancellation: true
    )

    public static let trailing = SubtreeRescanOptions(
        priority: .utility,
        resetsCancellation: false
    )
}

// MARK: - FileScanner

public final class FileScanner: @unchecked Sendable {

    private let cancelState = Mutex(false)
    private let directoryWorkQueue = Mutex<DirectoryWorkQueue?>(nil)
    private let computeBundleSizes: Bool
    private let deferTreeMaterialization: Bool
    private let mountTraversalScope: MountTraversalScope
    let filesystem: FilesystemProvider

    /// Test-only observation point after a transactional subtree splice and its aggregate
    /// repair have committed, but before `rescanSubtrees` returns to AppState. Production
    /// initializers always leave this nil. It exists to exercise the otherwise tiny
    /// supersession window where a newer scan can land after mutation but before the
    /// caller's token check.
    let subtreeRescanPostCommitHook: (@Sendable () -> Void)?

    /// Test seam for firmlink deduplication. Real firmlinks can't be created in a fixture
    /// (APFS has no directory hard links), so tests inject the set of paths that would be
    /// firmlink duplicates instead of depending on the host's `/usr/share/firmlinks`.
    /// `nil` means "read the live system table", which is what production always does.
    let firmlinkDuplicatesOverride: Set<String>?

    public init(
        filesystem: FilesystemProvider = RealFilesystemProvider(),
        computeBundleSizes: Bool = ProcessInfo.processInfo.environment["DIRWIZ_SKIP_BUNDLE_SIZES"] != "1",
        deferTreeMaterialization: Bool = ProcessInfo.processInfo.environment["DIRWIZ_DEFER_TREE"] != "0",
        mountTraversalScope requestedMountTraversalScope: MountTraversalScope = .selectedVolume
    ) {
        self.filesystem = filesystem
        self.computeBundleSizes = computeBundleSizes
        self.deferTreeMaterialization = deferTreeMaterialization
        self.mountTraversalScope = MountTraversalScope.resolved(
            requested: requestedMountTraversalScope,
            crossMountsEnvironmentValue: ProcessInfo.processInfo.environment["DIRWIZ_CROSS_MOUNTS"]
        )
        self.firmlinkDuplicatesOverride = nil
        self.subtreeRescanPostCommitHook = nil
    }

    /// Test-only initializer that injects the firmlink duplicate set directly.
    init(
        filesystem: FilesystemProvider = RealFilesystemProvider(),
        computeBundleSizes: Bool = false,
        deferTreeMaterialization: Bool = false,
        firmlinkDuplicates: Set<String>,
        mountTraversalScope requestedMountTraversalScope: MountTraversalScope = .selectedVolume
    ) {
        self.filesystem = filesystem
        self.computeBundleSizes = computeBundleSizes
        self.deferTreeMaterialization = deferTreeMaterialization
        self.mountTraversalScope = MountTraversalScope.resolved(
            requested: requestedMountTraversalScope,
            crossMountsEnvironmentValue: ProcessInfo.processInfo.environment["DIRWIZ_CROSS_MOUNTS"]
        )
        self.firmlinkDuplicatesOverride = firmlinkDuplicates
        self.subtreeRescanPostCommitHook = nil
    }

    /// Test-only initializer for observing the post-commit/pre-return supersession window.
    init(
        filesystem: FilesystemProvider = RealFilesystemProvider(),
        computeBundleSizes: Bool = false,
        deferTreeMaterialization: Bool = false,
        subtreeRescanPostCommitHook: @escaping @Sendable () -> Void,
        mountTraversalScope requestedMountTraversalScope: MountTraversalScope = .selectedVolume
    ) {
        self.filesystem = filesystem
        self.computeBundleSizes = computeBundleSizes
        self.deferTreeMaterialization = deferTreeMaterialization
        self.mountTraversalScope = MountTraversalScope.resolved(
            requested: requestedMountTraversalScope,
            crossMountsEnvironmentValue: ProcessInfo.processInfo.environment["DIRWIZ_CROSS_MOUNTS"]
        )
        self.firmlinkDuplicatesOverride = nil
        self.subtreeRescanPostCommitHook = subtreeRescanPostCommitHook
    }

    /// Resolves the duplicate set for a scan: an injected override wins (tests), otherwise
    /// the live system table, and only when the scan actually spans both sides.
    func resolveFirmlinkDuplicates(forScanRoot root: String) -> Set<String> {
        if let firmlinkDuplicatesOverride { return firmlinkDuplicatesOverride }
        guard FirmlinkTable.isActive(forScanRoot: root) else { return [] }
        return FirmlinkTable.loadSystemTable()
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
    ///   detached staging `FileTree` - nothing here touches the shared `tree` yet. This is
    ///   the fix for the reported incident: a serial per-root loop re-walking a large
    ///   fraction of the disk single-threaded took minutes where cold (fully parallel)
    ///   took ~20s.
    /// - **Phase B** (`applyStagedRoots`, serial, memory-bound): every staged target is
    ///   resolved by path against ONE snapshot, then all directory replacements are
    ///   installed through ONE transactional compaction. Resolve-once-then-single-mutation
    ///   is stronger than the old resolve-between-mutations discipline: no index is held
    ///   across an earlier mutation because there is no earlier mutation in the batch.
    ///   `rescannedRoots` are outermost/disjoint (`PathCollapse.outermostRoots`), so one
    ///   target can never be nested inside another.
    ///
    /// Resolution runs entirely against path strings before any mutation begins - never
    /// holds a tree index across a splice, since indices are garbage after any mutation
    /// that compacts the array (same discipline as `TreeActions.batchTrash(paths:tree:)`).
    ///
    /// Cancellation: `isCancelled` (this scanner's own flag, flipped by `cancel()`) and
    /// `Task.isCancelled` are both honored. Phase B builds replacement arrays off to the
    /// side and commits once, so cancellation during its long pass leaves `tree` exactly
    /// untouched; cancellation after a successful commit still gets the mandatory
    /// aggregate recompute before this method reports it.
    public func rescanSubtrees(
        _ changedDirectories: [String],
        tree: FileTree,
        progress: ScanProgress,
        shallowTargets: Set<String> = [],
        options: SubtreeRescanOptions = .interactive,
        onWillCommit: (@MainActor @Sendable () -> Void)? = nil
    ) async -> SubtreeRescanReport {
        let clock = ContinuousClock()
        let totalStart = clock.now
        let beforeNodeCount = tree.count

        // A scanner instance can be reused after cancel(), so an ordinary first tier
        // clears stale cancellation. A trailing tier is a continuation of the SAME
        // logical patch and deliberately does not: otherwise a cancel landing between
        // tiers would be erased just before the expensive deferred walk begins.
        if options.resetsCancellation {
            cancelState.withLock { $0 = false }
        }

        var unresolvedPaths: [String] = []
        var resolvedRequests: [(requestedPath: String, resolvedPath: String)] = []
        for changedPath in changedDirectories {
            guard let resolved = resolveRescanTarget(changedPath, tree: tree) else {
                unresolvedPaths.append(changedPath)
                continue
            }
            resolvedRequests.append((
                requestedPath: changedPath,
                resolvedPath: resolved
            ))
        }

        // A shallow request (see `JournalReplay.fileOnlyTargets`) stays shallow only
        // when it resolves to ITSELF: resolving upward means the tracked ancestor's
        // level composition is unknown, so it keeps full-subtree semantics. Deep
        // evidence for the same resolved path wins.
        var deepResolved = Set<String>()
        var shallowResolved = Set<String>()
        for request in resolvedRequests {
            let isShallow = shallowTargets.contains(request.requestedPath)
                && request.resolvedPath == Self.normalizePath(request.requestedPath)
            if isShallow {
                shallowResolved.insert(request.resolvedPath)
            } else {
                deepResolved.insert(request.resolvedPath)
            }
        }
        shallowResolved.subtract(deepResolved)

        let rescannedRoots = PathCollapse.outermostRoots(
            resolvedRequests.map { $0.resolvedPath },
            shallow: shallowResolved
        )
        let rescannedRootSet = Set(rescannedRoots)
        var contributingRequestedPathsByRoot = Dictionary(
            uniqueKeysWithValues: rescannedRoots.map { ($0, [String]()) }
        )
        for request in resolvedRequests {
            var candidate = request.resolvedPath
            while true {
                if rescannedRootSet.contains(candidate) {
                    contributingRequestedPathsByRoot[candidate, default: []]
                        .append(request.requestedPath)
                    break
                }
                let parent = (candidate as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != candidate else { break }
                candidate = parent
            }
        }
        let treeRoot = tree.path(at: 0)

        // Abandon before Phase A, and critically before ANY mutation, when the caller
        // cannot trust a partial patch. AppState has always treated either shape as a
        // cold-fallback signal; doing the preflight here strengthens that intended rule
        // by ensuring a mixed valid+unresolved batch cannot alter the visible tree before
        // AppState notices the report. A SHALLOW root-level target is exempt: files
        // changing directly inside the scan root only require reconciling the root's own
        // entry level, which Phase A0 below handles - abandoning for it was one of the
        // two paths that kept every launch cold.
        let deepRootLevelTarget = rescannedRoots.contains(treeRoot)
            && !shallowResolved.contains(treeRoot)
        if !unresolvedPaths.isEmpty || deepRootLevelTarget {
            let now = clock.now
            let metrics = SubtreeRescanMetrics(
                preflightAndPlanningSeconds: Self.wallSeconds(totalStart.duration(to: now)),
                totalSeconds: Self.wallSeconds(totalStart.duration(to: now)),
                beforeNodeCount: beforeNodeCount,
                afterNodeCount: tree.count,
                requestedPathCount: changedDirectories.count,
                rescannedRootCount: rescannedRoots.count
            )
            return SubtreeRescanReport(
                requestedPaths: changedDirectories,
                rescannedRoots: rescannedRoots,
                unresolvedPaths: unresolvedPaths,
                wasCancelled: isCancelled || Task.isCancelled,
                metrics: metrics
            )
        }

        // One instance shared across every target in this batch - matches cold scan's
        // single firmlink/hardlink guard for the whole operation, not one per target. Its
        // internal Mutex makes sharing it across Phase A's concurrent tasks safe.
        //
        // Seeded with the same firmlink duplicates the cold scan uses, keyed off the tree's
        // own root: the warm-start equivalence gate asserts a patched tree equals a fresh
        // cold scan, so if cold skips the Data-side copies and a splice re-enumerated them,
        // the two would diverge the moment a firmlinked path changed.
        let rootDevice = filesystem.deviceAndInode(forPath: treeRoot)?.device
        let visited = VisitedDirectories(
            rootDevice: rootDevice,
            mountTraversalScope: tree.mountTraversalScope,
            firmlinkDuplicates: resolveFirmlinkDuplicates(forScanRoot: treeRoot)
        )

        // A changed mount point can itself become a Phase-A root. Check it before seeding
        // staging; otherwise the root queue entry bypasses the child-enqueue gate and an
        // individual warm/living patch absorbs the foreign filesystem cold scan excludes.
        let plans = planRescanTargets(rescannedRoots, tree: tree).filter { plan in
            guard let device = filesystem.deviceAndInode(forPath: plan.targetPath)?.device,
                  visited.isMountBoundary(device: device) else { return true }
            progress.incrementSkippedMount(path: plan.targetPath)
            return false
        }

        // ---- Phase A0: shallow one-level reconcile ---------------------------------
        // A shallow target's fresh entry level is read WITHOUT descending. If its
        // (name, type) set matches the cached children, only metadata changed there and
        // the target is applied in place before Phase B; otherwise it PROMOTES to the
        // ordinary full-subtree semantics below. Bundle targets keep bundle semantics
        // regardless of kind.
        var shallowLevels: [String: FileTree] = [:]
        var promotedRoots: [String] = []
        let shallowPlans = plans.filter {
            shallowResolved.contains($0.targetPath) && !$0.isBundle
        }
        if !shallowPlans.isEmpty {
            let levelSnapshot = tree.pathBuildingSnapshot()
            let rawFilesystemForScan = filesystem as? RealFilesystemProvider
            let rawBuffer = rawFilesystemForScan.map { _ in
                UnsafeMutableRawPointer.allocate(
                    byteCount: RealFilesystemProvider.directoryBufferSize,
                    alignment: 16
                )
            }
            defer { rawBuffer?.deallocate() }
            var rawScratch = RawScanScratch()
            var rawArena = RawScanArena()
            for plan in shallowPlans {
                guard !isCancelled, !Task.isCancelled else { break }
                // A throwaway visited guard: A0 never recurses, and sharing the batch's
                // guard would mark this level's subdirectories visited before Phase A
                // legitimately enumerates a promoted subtree.
                let levelVisited = VisitedDirectories(
                    rootDevice: rootDevice,
                    mountTraversalScope: tree.mountTraversalScope,
                    firmlinkDuplicates: resolveFirmlinkDuplicates(forScanRoot: treeRoot)
                )
                if let di = filesystem.deviceAndInode(forPath: plan.targetPath) {
                    _ = levelVisited.insert(dev: di.device, inode: di.inode)
                }
                let staging = FileTree(stagingCapacityHint: 512)
                var placeholderRoot = FileNode()
                placeholderRoot.isDirectory = true
                _ = staging.addNode(placeholderRoot, name: "")
                scanDirectory(
                    dirPath: plan.targetPath,
                    parentIndex: 0,
                    tree: staging,
                    progress: progress,
                    visited: levelVisited,
                    enqueue: { _, _ in },   // one level only: never descend
                    maybeUpdateProgress: { _ in },
                    rawFilesystem: rawFilesystemForScan,
                    rawBuffer: rawBuffer,
                    rawScratch: &rawScratch,
                    deferredBuilder: nil,
                    rawArena: &rawArena
                )
                if Self.levelMatchesCachedChildren(
                    of: plan.targetPath,
                    staging: staging,
                    nodes: levelSnapshot.nodes,
                    stringPool: levelSnapshot.stringPool,
                    rootPath: levelSnapshot.rootPath
                ) {
                    shallowLevels[plan.targetPath] = staging
                } else {
                    promotedRoots.append(plan.targetPath)
                }
            }
        }

        // A promotion at the scan root means the root's own level changed shape - the
        // existing root-level cold fallback applies, before any mutation.
        if promotedRoots.contains(treeRoot) {
            let now = clock.now
            let metrics = SubtreeRescanMetrics(
                preflightAndPlanningSeconds: Self.wallSeconds(totalStart.duration(to: now)),
                totalSeconds: Self.wallSeconds(totalStart.duration(to: now)),
                beforeNodeCount: beforeNodeCount,
                afterNodeCount: tree.count,
                requestedPathCount: changedDirectories.count,
                rescannedRootCount: rescannedRoots.count
            )
            return SubtreeRescanReport(
                requestedPaths: changedDirectories,
                rescannedRoots: rescannedRoots,
                unresolvedPaths: unresolvedPaths,
                wasCancelled: isCancelled || Task.isCancelled,
                metrics: metrics
            )
        }

        // Everything that is not a metadata-equal shallow level keeps full-subtree
        // semantics (deep, bundles, promotions, and shallow plans a cancellation
        // skipped). Promotions claim their descendants; shallow levels nested inside
        // any final deep root are covered by that root's staging and dropped.
        let finalDeepRoots = PathCollapse.outermostRoots(
            rescannedRoots.filter { shallowLevels[$0] == nil }
        )
        let finalDeepSet = Set(finalDeepRoots)
        let keptShallowRoots = rescannedRoots.filter { path in
            shallowLevels[path] != nil && !finalDeepRoots.contains { ancestor in
                path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
            }
        }
        let keptShallowSet = Set(keptShallowRoots)
        shallowLevels = shallowLevels.filter { keptShallowSet.contains($0.key) }
        let appliedRootOrder = rescannedRoots.filter {
            finalDeepSet.contains($0) || keptShallowSet.contains($0)
        }
        let deepPlans = plans.filter { finalDeepSet.contains($0.targetPath) }
        let preflightAndPlanningEnd = clock.now

        let phaseAStart = clock.now
        let staged = await stageChangedRoots(
            deepPlans,
            progress: progress,
            visited: visited,
            priority: options.priority
        )
        let phaseAEnd = clock.now
        let rootStaging = appliedRootOrder.compactMap { path -> SubtreeRescanMetrics.RootStaging? in
            if let level = shallowLevels[path] {
                return SubtreeRescanMetrics.RootStaging(
                    path: path,
                    contributingRequestedPaths: contributingRequestedPathsByRoot[path] ?? [],
                    actualStagedItemCount: max(0, level.count - 1)
                )
            }
            guard let result = staged[path] else { return nil }
            let actualStagedItemCount: Int
            switch result {
            case .directory(let staging):
                actualStagedItemCount = staging.count
            case .bundle:
                actualStagedItemCount = 1
            }
            return SubtreeRescanMetrics.RootStaging(
                path: path,
                contributingRequestedPaths: contributingRequestedPathsByRoot[path] ?? [],
                actualStagedItemCount: actualStagedItemCount
            )
        }
        let stagedNodeCount = staged.values.reduce(into: 0) { count, result in
            guard case .directory(let staging) = result else { return }
            let sum = count.addingReportingOverflow(staging.count)
            count = sum.overflow ? Int.max : sum.partialValue
        }
        let actualStagedItemCount = rootStaging.reduce(into: 0) { count, root in
            let sum = count.addingReportingOverflow(root.actualStagedItemCount)
            count = sum.overflow ? Int.max : sum.partialValue
        }

        // The cached-tree estimate cannot see growth since the cache horizon. Once Phase A
        // has the exact live count, enforce the caller's remaining budget before
        // `onWillCommit` and before Phase B can renumber or otherwise mutate the tree.
        // Cancellation wins over this policy result: a partial/cancelled staging pass is
        // reported as cancellation, not mislabelled as an oversized coherent patch.
        if !isCancelled,
           !Task.isCancelled,
           let maximumStagedItemCount = options.maximumStagedItemCount,
           actualStagedItemCount > maximumStagedItemCount {
            let totalEnd = clock.now
            let metrics = SubtreeRescanMetrics(
                preflightAndPlanningSeconds: Self.wallSeconds(
                    totalStart.duration(to: preflightAndPlanningEnd)
                ),
                phaseAStagingSeconds: Self.wallSeconds(
                    phaseAStart.duration(to: phaseAEnd)
                ),
                totalSeconds: Self.wallSeconds(totalStart.duration(to: totalEnd)),
                beforeNodeCount: beforeNodeCount,
                stagedNodeCount: stagedNodeCount,
                afterNodeCount: tree.count,
                requestedPathCount: changedDirectories.count,
                rescannedRootCount: rescannedRoots.count,
                plannedRootCount: plans.count,
                stagedRootCount: staged.count,
                rootStaging: rootStaging
            )
            return SubtreeRescanReport(
                requestedPaths: changedDirectories,
                rescannedRoots: appliedRootOrder,
                unresolvedPaths: unresolvedPaths,
                stagedItemBudgetExceeded: .init(
                    actualStagedItemCount: actualStagedItemCount,
                    maximumStagedItemCount: maximumStagedItemCount
                ),
                metrics: metrics
            )
        }

        // Metadata-only shallow levels are applied in place BEFORE any compaction: no
        // index is invalidated, so this never needs the onWillCommit pause, and the
        // batch's mandatory aggregate recompute repairs the totals it touches.
        var appliedShallowRoots: [String] = []
        if !shallowLevels.isEmpty, !isCancelled, !Task.isCancelled {
            let shallowUnresolved = applyShallowLevels(shallowLevels, tree: tree)
            unresolvedPaths.append(contentsOf: shallowUnresolved)
            let failed = Set(shallowUnresolved)
            appliedShallowRoots = keptShallowRoots.filter { !failed.contains($0) }
        }

        // Give a UI caller one MainActor turn to suspend index-based interaction before
        // the transactional compaction renumbers the displayed tree. The callback is
        // deliberately immediately adjacent to Phase B: Phase A can take seconds and
        // leaves every old index valid, so blocking navigation for the whole enumeration
        // would defeat warm start's browsable-stale-view contract.
        if !staged.isEmpty {
            await onWillCommit?()
        }

        let phaseB = applyStagedRoots(
            finalDeepRoots,
            staged: staged,
            tree: tree,
            progress: progress
        )
        unresolvedPaths.append(contentsOf: phaseB.unresolvedPaths)

        // A successful transactional splice deliberately leaves aggregate directory
        // totals stale. Repair them before observing any cancellation that raced after
        // commit; otherwise a structurally valid but numerically incoherent tree could
        // escape. In-place shallow updates change file sizes the same way, so they need
        // the identical repair even when no structural splice committed.
        var aggregateRecomputeSeconds = 0.0
        if phaseB.committed || !appliedShallowRoots.isEmpty {
            let aggregateStart = clock.now
            tree.recomputeAggregates()
            aggregateRecomputeSeconds = Self.wallSeconds(
                aggregateStart.duration(to: clock.now)
            )
            subtreeRescanPostCommitHook?()
        }

        let afterNodeCount = tree.count
        let totalEnd = clock.now
        let metrics = SubtreeRescanMetrics(
            preflightAndPlanningSeconds: Self.wallSeconds(
                totalStart.duration(to: preflightAndPlanningEnd)
            ),
            phaseAStagingSeconds: Self.wallSeconds(
                phaseAStart.duration(to: phaseAEnd)
            ),
            phaseBTargetResolutionSeconds: phaseB.targetResolutionSeconds,
            phaseBStructuralCompactionSeconds: phaseB.structuralCompactionSeconds,
            postCommitMetadataSeconds: phaseB.postCommitMetadataSeconds,
            aggregateRecomputeSeconds: aggregateRecomputeSeconds,
            totalSeconds: Self.wallSeconds(totalStart.duration(to: totalEnd)),
            beforeNodeCount: beforeNodeCount,
            stagedNodeCount: stagedNodeCount,
            appendedNodeCount: phaseB.appendedNodeCount,
            removedNodeCount: phaseB.removedNodeCount,
            afterNodeCount: afterNodeCount,
            requestedPathCount: changedDirectories.count,
            rescannedRootCount: appliedRootOrder.count,
            plannedRootCount: plans.count,
            stagedRootCount: staged.count,
            resolvedTargetCount: phaseB.resolvedTargetCount,
            structurallyReplacedRootCount: phaseB.structurallyReplacedRootCount,
            appliedRootCount: phaseB.appliedRootCount + appliedShallowRoots.count,
            rootStaging: rootStaging
        )
        return SubtreeRescanReport(
            requestedPaths: changedDirectories,
            rescannedRoots: appliedRootOrder,
            unresolvedPaths: unresolvedPaths,
            wasCancelled: isCancelled || Task.isCancelled,
            shallowRoots: appliedShallowRoots,
            metrics: metrics
        )
    }

    /// One collapsed root's batch-start shape: just enough to decide, up front, whether
    /// Phase A should enumerate it as a directory or compute it as an opaque bundle leaf.
    private struct RootPlan {
        let targetPath: String
        let isBundle: Bool
    }

    /// What Phase A produced for one root, keyed by path in `stageChangedRoots`'s result -
    /// never keyed by index, since indices from the batch-start snapshot are meaningless
    /// once Phase B starts splicing.
    private enum StageResult: Sendable {
        case directory(staging: FileTree)
        case bundle(fileSize: UInt64, allocatedSize: UInt64)
    }

    /// Resolves every collapsed root's current shape ONCE, against the tree as it stands
    /// at the very start of this batch - before any splicing happens. See
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

    /// (name, isDirectory, isBundle) equality between a shallow target's fresh one-level
    /// staging and its cached direct children. Equality means only metadata changed at
    /// this level; anything else (created, removed, renamed, or type-swapped entries)
    /// requires full-subtree semantics and promotes the target.
    private static func levelMatchesCachedChildren(
        of targetPath: String,
        staging: FileTree,
        nodes: [FileNode],
        stringPool: Data,
        rootPath: String
    ) -> Bool {
        guard let components = relativeComponents(of: targetPath, rootPath: rootPath),
              let targetIndex = FileTree.descendPath(
                  components, nodes: nodes, stringPool: stringPool
              ),
              Int(targetIndex) < nodes.count else { return false }

        var cached: [String: (isDirectory: Bool, isBundle: Bool)] = [:]
        let target = nodes[Int(targetIndex)]
        if target.firstChildIndex != FileNode.invalid {
            let start = Int(target.firstChildIndex)
            let end = min(start + Int(target.childCount), nodes.count)
            for child in start..<end {
                let node = nodes[child]
                cached[Self.nodeName(node, in: stringPool)] =
                    (node.isDirectory, node.isBundle)
            }
        }

        let level = staging.pathBuildingSnapshot()
        var freshCount = 0
        for i in level.nodes.indices where i != 0 && level.nodes[i].parentIndex == 0 {
            let node = level.nodes[i]
            freshCount += 1
            guard let match = cached[Self.nodeName(node, in: level.stringPool)],
                  match.isDirectory == node.isDirectory,
                  match.isBundle == node.isBundle else { return false }
        }
        return freshCount == cached.count
    }

    /// Applies metadata-only shallow reconciles: copy every non-structural field from
    /// the fresh level onto the existing child nodes, matched by name. Runs BEFORE any
    /// compaction, so no index is invalidated. Directory and bundle children keep their
    /// cached sizes - non-bundle totals are recomputed by the batch's mandatory
    /// `recomputeAggregates()`, and a bundle's opaque size only changes via its own
    /// bundle-target events. Returns targets that could no longer be resolved.
    private func applyShallowLevels(
        _ levels: [String: FileTree],
        tree: FileTree
    ) -> [String] {
        var unresolved: [String] = []
        let snapshot = tree.pathBuildingSnapshot()
        for (targetPath, staging) in levels {
            guard let components = Self.relativeComponents(
                      of: targetPath, rootPath: snapshot.rootPath
                  ),
                  let targetIndex = FileTree.descendPath(
                      components, nodes: snapshot.nodes, stringPool: snapshot.stringPool
                  ),
                  Int(targetIndex) < snapshot.nodes.count else {
                unresolved.append(targetPath)
                continue
            }

            var cachedByName: [String: UInt32] = [:]
            let target = snapshot.nodes[Int(targetIndex)]
            if target.firstChildIndex != FileNode.invalid {
                let start = Int(target.firstChildIndex)
                let end = min(start + Int(target.childCount), snapshot.nodes.count)
                for child in start..<end {
                    cachedByName[Self.nodeName(snapshot.nodes[child], in: snapshot.stringPool)] =
                        UInt32(child)
                }
            }

            let level = staging.pathBuildingSnapshot()
            for i in level.nodes.indices where i != 0 && level.nodes[i].parentIndex == 0 {
                let fresh = level.nodes[i]
                guard let cachedIndex = cachedByName[
                    Self.nodeName(fresh, in: level.stringPool)
                ] else { continue }
                tree.updateNode(at: cachedIndex) { node in
                    if !fresh.isDirectory {
                        node.fileSize = fresh.fileSize
                        node.allocatedSize = fresh.allocatedSize
                    }
                    node.inode = fresh.inode
                    node.device = fresh.device
                    node.extensionHash = fresh.extensionHash
                    node.flags = fresh.flags
                    node.modifiedDate = fresh.modifiedDate
                }
            }

            // The target's own mtime changed - that is why its level was reported.
            // Mirrors the deep path's post-commit directory-mtime refresh.
            if let mtime = Self.modifiedDate(atPath: targetPath) {
                tree.updateNode(at: targetIndex) { $0.modifiedDate = mtime }
            }
        }
        return unresolved
    }

    private static func nodeName(_ node: FileNode, in pool: Data) -> String {
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard start >= 0, end <= pool.count else { return "" }
        return String(decoding: pool[start..<end], as: UTF8.self)
    }

    /// Phase A: enumerate every plan's on-disk subtree (or compute its bundle size)
    /// concurrently, bounded to the same worker-count knob cold scan uses
    /// (`DIRWIZ_SCAN_WORKERS`). Every directory plan's enumeration work - its root path
    /// AND every subdirectory discovered under it - feeds into ONE shared
    /// `RescanWorkQueue` drained by that many workers, rather than giving each root its
    /// own fixed slice of the pool: a single directory's own entries can't be split
    /// across workers (`getattrlistbulk` reads one handle's entries as one sequential
    /// operation), so across-roots-only parallelism helps when there are many
    /// small-to-medium roots but does nothing extra for the reported incident's actual
    /// shape - ONE dominant root sitting high in the tree. Sharing one queue means idle
    /// workers (roots with nothing left) naturally flow into whichever root still has
    /// work, with no size estimate needed up front. Nothing here touches the shared
    /// `tree`: each directory plan enumerates into its OWN small, detached staging
    /// `FileTree` that `applyStagedRoots` later splices in via `FileTree.installSubtree`.
    private func stageChangedRoots(
        _ plans: [RootPlan],
        progress: ScanProgress,
        visited: VisitedDirectories,
        priority: SubtreeRescanOptions.Priority
    ) async -> [String: StageResult] {
        guard !plans.isEmpty else { return [:] }

        let directoryPlans = plans.filter { !$0.isBundle }
        let bundlePlans = plans.filter { $0.isBundle }

        var stagingByPath: [String: FileTree] = [:]
        stagingByPath.reserveCapacity(directoryPlans.count)
        let sharedQueue = RescanWorkQueue()
        for plan in directoryPlans {
            // Mark each root itself visited before seeding the queue, same as the cold
            // scan marks its root and the old single-consumer drain did - so a firmlink
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
        // staging tree is just the placeholder with no children - installing that would
        // wrongly wipe out the target's real, pre-existing children rather than leaving
        // them alone, so `applyStagedRoots` must see `nil` (not `.directory`) for it.
        let touchedRoots = Mutex(Set<String>())

        // Reports one more root done, whichever kind it was - thread-safe from any
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
        let dispatchQoS: DispatchQoS.QoSClass = priority == .utility
            ? .utility
            : .userInitiated
        let taskPriority: TaskPriority = priority == .utility
            ? .low
            : .userInitiated
        var results: [String: StageResult] = [:]
        results.reserveCapacity(plans.count)

        await withTaskGroup(of: (String, StageResult)?.self) { group in
            // Bundle plans: one Task each, no further internal parallelism possible -
            // computing a bundle's size is a single recursive walk, not splittable.
            for plan in bundlePlans {
                group.addTask(priority: taskPriority) {
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
            // queue - plain OS threads (like cold scan's own worker pool), not Swift
            // Tasks, since these loops legitimately block on `RescanWorkQueue.next()`
            // while other workers still have work; blocking a Swift Task body that way
            // risks starving the cooperative thread pool cold scan and everything else
            // shares.
            if !directoryPlans.isEmpty {
                group.addTask(priority: taskPriority) {
                    let rawFilesystemForScan = self.filesystem as? RealFilesystemProvider
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let dispatchGroup = DispatchGroup()
                        for _ in 0..<workerCount {
                            dispatchGroup.enter()
                            DispatchQueue.global(qos: dispatchQoS).async {
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
                        dispatchGroup.notify(queue: .global(qos: dispatchQoS)) {
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

        // Every directory plan's staging tree gets installed here - none of them flow
        // through the task group's return value (only bundle plans do, above), since
        // `stagingByPath` already has a live reference to each one that workers wrote
        // into directly. Skip any root that never got touched (cancelled before its own
        // queue entry was ever dequeued): its staging tree is just the untouched
        // placeholder, and installing that would wipe out the target's real children -
        // leaving it out of `results` entirely makes `applyStagedRoots` see `nil` and
        // correctly leave that root untouched instead.
        let touched = touchedRoots.withLock { $0 }
        for (targetPath, staging) in stagingByPath where results[targetPath] == nil && touched.contains(targetPath) {
            results[targetPath] = .directory(staging: staging)
        }

        return results
    }

    private struct PhaseBTarget {
        let path: String
        let oldIndex: UInt32
        let expectedDevice: Int32
        let expectedInode: UInt64
        let result: StageResult
    }

    private struct PhaseBOutcome {
        let committed: Bool
        let unresolvedPaths: [String]
        let targetResolutionSeconds: Double
        let structuralCompactionSeconds: Double
        let postCommitMetadataSeconds: Double
        let appendedNodeCount: Int
        let removedNodeCount: Int
        let resolvedTargetCount: Int
        let structurallyReplacedRootCount: Int
        let appliedRootCount: Int

        static let notCommitted = PhaseBOutcome(
            committed: false,
            unresolvedPaths: [],
            targetResolutionSeconds: 0,
            structuralCompactionSeconds: 0,
            postCommitMetadataSeconds: 0,
            appendedNodeCount: 0,
            removedNodeCount: 0,
            resolvedTargetCount: 0,
            structurallyReplacedRootCount: 0,
            appliedRootCount: 0
        )
    }

    /// Resolve every Phase B target against one immutable snapshot. The returned indices
    /// remain valid until the one transactional compaction below; there is no mutation
    /// between this function and `applyStagedReplacements`.
    private static func resolvePhaseBTargets(
        _ rescannedRoots: [String],
        staged: [String: StageResult],
        tree: FileTree
    ) -> (targets: [PhaseBTarget], unresolvedPaths: [String]) {
        let snapshot = tree.pathBuildingSnapshot()
        var targets: [PhaseBTarget] = []
        var unresolvedPaths: [String] = []
        targets.reserveCapacity(staged.count)

        for targetPath in rescannedRoots {
            // Cancellation before Phase A touched a root deliberately leaves no staged
            // result. Preserve that root untouched rather than installing an empty tree.
            guard let result = staged[targetPath] else { continue }
            guard let components = relativeComponents(
                      of: targetPath,
                      rootPath: snapshot.rootPath
                  ),
                  let targetIndex = FileTree.descendPath(
                      components,
                      nodes: snapshot.nodes,
                      stringPool: snapshot.stringPool
                  ),
                  Int(targetIndex) < snapshot.nodes.count else {
                unresolvedPaths.append(targetPath)
                continue
            }
            let node = snapshot.nodes[Int(targetIndex)]
            targets.append(PhaseBTarget(
                path: targetPath,
                oldIndex: targetIndex,
                expectedDevice: node.device,
                expectedInode: node.inode,
                result: result
            ))
        }
        return (targets, unresolvedPaths)
    }

    /// Phase B: resolve every target once, then compact exactly once. Directory mtimes
    /// and opaque bundle sizes are applied only after the transaction commits; their
    /// post-commit path resolution never feeds another compaction and therefore cannot
    /// invalidate a held splice target.
    private func applyStagedRoots(
        _ rescannedRoots: [String],
        staged: [String: StageResult],
        tree: FileTree,
        progress: ScanProgress
    ) -> PhaseBOutcome {
        guard !isCancelled, !Task.isCancelled else {
            return .notCommitted
        }

        // This helper's snapshot dies on return. Holding it while the primitive publishes
        // its rebuilt arrays would retain the full pre-splice tree longer than necessary.
        let clock = ContinuousClock()
        let targetResolutionStart = clock.now
        let resolved = Self.resolvePhaseBTargets(
            rescannedRoots,
            staged: staged,
            tree: tree
        )
        let targetResolutionSeconds = Self.wallSeconds(
            targetResolutionStart.duration(to: clock.now)
        )
        guard resolved.unresolvedPaths.isEmpty else {
            return PhaseBOutcome(
                committed: false,
                unresolvedPaths: resolved.unresolvedPaths,
                targetResolutionSeconds: targetResolutionSeconds,
                structuralCompactionSeconds: 0,
                postCommitMetadataSeconds: 0,
                appendedNodeCount: 0,
                removedNodeCount: 0,
                resolvedTargetCount: resolved.targets.count,
                structurallyReplacedRootCount: 0,
                appliedRootCount: 0
            )
        }
        guard !resolved.targets.isEmpty else {
            return PhaseBOutcome(
                committed: false,
                unresolvedPaths: [],
                targetResolutionSeconds: targetResolutionSeconds,
                structuralCompactionSeconds: 0,
                postCommitMetadataSeconds: 0,
                appendedNodeCount: 0,
                removedNodeCount: 0,
                resolvedTargetCount: 0,
                structurallyReplacedRootCount: 0,
                appliedRootCount: 0
            )
        }

        let folderCount = resolved.targets.count
        progress.updateCurrentPath(
            "Applying \(folderCount) folder\(folderCount == 1 ? "" : "s")…"
        )
        Task { await MainActor.run {
            progress.publishCounters()
        } }

        let replacements: [(target: UInt32, staged: FileTree)] = resolved.targets.compactMap {
            guard case .directory(let staging) = $0.result else { return nil }
            return (target: $0.oldIndex, staged: staging)
        }
        let proposedAppendedNodeCount = replacements.reduce(into: 0) { count, replacement in
            let appended = max(0, replacement.staged.count - 1)
            let sum = count.addingReportingOverflow(appended)
            count = sum.overflow ? Int.max : sum.partialValue
        }
        let structuralBeforeNodeCount = tree.count
        let structuralCompactionStart = clock.now
        let committed = tree.applyStagedReplacements(
            replacements,
            shouldCancel: { self.isCancelled || Task.isCancelled }
        )
        let structuralCompactionSeconds = Self.wallSeconds(
            structuralCompactionStart.duration(to: clock.now)
        )
        guard committed else {
            return PhaseBOutcome(
                committed: false,
                unresolvedPaths: [],
                targetResolutionSeconds: targetResolutionSeconds,
                structuralCompactionSeconds: structuralCompactionSeconds,
                postCommitMetadataSeconds: 0,
                appendedNodeCount: 0,
                removedNodeCount: 0,
                resolvedTargetCount: resolved.targets.count,
                structurallyReplacedRootCount: 0,
                appliedRootCount: 0
            )
        }
        let structuralAfterNodeCount = tree.count
        let removedNodeCount: Int
        let sourcePlusAppended = structuralBeforeNodeCount.addingReportingOverflow(
            proposedAppendedNodeCount
        )
        if sourcePlusAppended.overflow {
            removedNodeCount = Int.max
        } else {
            removedNodeCount = max(
                0,
                sourcePlusAppended.partialValue - structuralAfterNodeCount
            )
        }

        // The compaction keeps every target itself, so each path must still resolve.
        // Resolve metadata destinations only after the transactional commit: cancellation
        // before/during the long pass then leaves the exact old tree, not a tree with a
        // few bundle sizes or mtimes changed ahead of an abandoned splice.
        var postCommitUnresolved: [String] = []
        let postCommitMetadataStart = clock.now
        for target in resolved.targets {
            guard let currentIndex = Self.resolveCurrentIndex(of: target.path, tree: tree) else {
                postCommitUnresolved.append(target.path)
                continue
            }

            if case .bundle(let fileSize, let allocatedSize) = target.result {
                _ = tree.setNodeSizeAndPropagate(
                    at: currentIndex,
                    fileSize: fileSize,
                    allocatedSize: allocatedSize,
                    expectedDevice: target.expectedDevice,
                    expectedInode: target.expectedInode
                )
            }

            // A changed dir's mtime is user-visible in the table.
            if let mtime = Self.modifiedDate(atPath: target.path) {
                tree.updateNode(at: currentIndex) { $0.modifiedDate = mtime }
            }
        }
        let postCommitMetadataSeconds = Self.wallSeconds(
            postCommitMetadataStart.duration(to: clock.now)
        )

        return PhaseBOutcome(
            committed: true,
            unresolvedPaths: postCommitUnresolved,
            targetResolutionSeconds: targetResolutionSeconds,
            structuralCompactionSeconds: structuralCompactionSeconds,
            postCommitMetadataSeconds: postCommitMetadataSeconds,
            appendedNodeCount: proposedAppendedNodeCount,
            removedNodeCount: removedNodeCount,
            resolvedTargetCount: resolved.targets.count,
            structurallyReplacedRootCount: replacements.count,
            appliedRootCount: resolved.targets.count
        )
    }

    private static func wallSeconds(_ duration: ContinuousClock.Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Re-resolve post-commit metadata destinations by durable path. Kept in a separate
    /// function so its COW snapshot is provably released before `updateNode` or
    /// `setNodeSizeAndPropagate` mutates the rebuilt array; holding the snapshot across
    /// either write would force an unnecessary whole-array copy.
    private static func resolveCurrentIndex(of targetPath: String, tree: FileTree) -> UInt32? {
        let snapshot = tree.pathBuildingSnapshot()
        guard let components = Self.relativeComponents(of: targetPath, rootPath: snapshot.rootPath) else {
            return nil
        }
        return FileTree.descendPath(components, nodes: snapshot.nodes, stringPool: snapshot.stringPool)
    }

    /// Same worker-count sizing cold scan uses for its `DirectoryWorkQueue` pool
    /// (`DIRWIZ_SCAN_WORKERS`, defaulting to 4–6 based on core count) - reused here so
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
    /// on disk and already resolves inside `tree` - handles deleted dirs, brand-new dirs
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
    /// (which has no modification-time accessor and is out of scope to extend here) - this
    /// only degrades gracefully on a mocked provider in tests, since real subtree rescans
    /// always run against `RealFilesystemProvider`.
    private static func modifiedDate(atPath path: String) -> UInt32? {
        var s = stat()
        guard lstat(path, &s) == 0 else { return nil }
        return UInt32(clamping: max(0, Int(s.st_mtimespec.tv_sec)))
    }

    /// Scan the filesystem at `path`, returning the tree.
    /// The tree is populated incrementally - assign it to your UI state before awaiting
    /// this method if you want live updates.
    /// Pass the returned FileTree to the UI immediately; it's populated in-place during scan.
    ///
    /// `estimatedItemsHint`: when the caller already knows a trustworthy item-count
    /// estimate - e.g. the previous scan's count, for a refresh behind a stale view -
    /// pass it here to skip the statfs-based inode estimate entirely. That estimate is
    /// only loosely correlated with the true count on APFS (see `ScanProgress.
    /// fractionCompleted`'s doc comment); a prior scan's real count is a far better
    /// predictor of a refresh's total than inode statistics are.
    ///
    /// `publishesTerminalProgress` defaults to the standalone scanner contract. AppState passes
    /// `false` so its durable ownership and displayed-tree handoff can finish before the shared UI
    /// exposes completion; final counters, elapsed time, and cancellation still publish normally.
    public func scan(
        path: String,
        progress: ScanProgress,
        tree: FileTree,
        estimatedItemsHint: Int = 0,
        publishesTerminalProgress: Bool = true
    ) async {
        // Reset cancellation so a scanner instance can be reused after cancel().
        cancelState.withLock { $0 = false }

        // Estimate total items using inode counts (blocking I/O, done off main thread) -
        // skipped entirely when the caller supplied a trustworthy hint.
        var estimatedItems = max(0, estimatedItemsHint)
        if estimatedItems == 0, let sf = filesystem.volumeStats(forPath: path) {
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
        tree.setMountTraversalScope(mountTraversalScope)
        // Every scan path (raw and provider-driven) records per-file link counts into
        // node flags, so mark them trustworthy for HardlinkFinder's fast path.
        tree.setLinkCountsCaptured(true)

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

        // Visited directory tracker (prevents hardlink/mount double-counting), seeded with
        // the firmlink duplicates that (dev, inode) provably can't catch - but only when
        // this scan actually covers both sides. A scan rooted at or below the Data volume
        // must enumerate everything (see `FirmlinkTable.isActive`).
        let firmlinkDuplicates = resolveFirmlinkDuplicates(forScanRoot: path)
        if !firmlinkDuplicates.isEmpty {
            scanLog.notice("Firmlink dedup active for \(path, privacy: .public): \(firmlinkDuplicates.count, privacy: .public) duplicate Data-volume paths will be skipped")
        }
        let rootIdentity = filesystem.deviceAndInode(forPath: path)
        let visited = VisitedDirectories(
            rootDevice: rootIdentity?.device,
            mountTraversalScope: mountTraversalScope,
            firmlinkDuplicates: firmlinkDuplicates
        )

        // Mark root as visited
        if let di = rootIdentity {
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
        // 8 measured ~7% faster than 6 on a 10-core machine (~/code fixture: 5.51s → 5.12s);
        // 10/12 workers showed no further gain - syscall latency, not core count, is the
        // limiting factor beyond this point.
        let defaultWorkerCount = isNetworkFS
            ? 4
            : min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
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

        // Finalize progress - publish final counters before marking complete
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
        let wasCancelled = isCancelled
        await MainActor.run {
            progress.publishCounters(forceLayoutRevision: true)
            progress.elapsedTime = totalElapsed
            if publishesTerminalProgress {
                progress.isScanning = false
                progress.scanComplete = true
            }
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

        // false means open() failed (permission denied, etc.) - matches original behaviour.
        let opened = filesystem.forEachDirectoryEntry(path: dirPath) { rawEntry in
            guard !isCancelled else { return false }

            let entryName = rawEntry.name
            guard !entryName.isEmpty, entryName != ".", entryName != ".." else { return true }

            // Skip symlinks entirely - following them causes double-counting and potential
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
                if rawEntry.linkCount > 1 {
                    node.hasMultipleHardlinks = true
                }
            }

            // Detect bundles: mark as opaque leaves and skip recursive enqueue.
            let directoryPath = isDir ? appendPathComponent(dirPath, entryName) : nil
            let isForeignMount = directoryPath != nil
                && visited.isMountBoundary(device: rawEntry.device)
            let isBundle = isDir && !isForeignMount && isBundleName(entryName)
            if isBundle {
                node.isBundle = true
            }

            let childLocalIndex = children.count
            children.append((node: node, name: entryName))

            if isDir {
                if isForeignMount, let directoryPath {
                    progress.incrementSkippedMount(path: directoryPath)
                } else if isBundle {
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
            progress.incrementSkippedDirectories(path: dirPath)
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

        // Enqueue subdirectories - skips already-visited (dev, inode) pairs (hardlinks,
        // repeat mounts) and firmlink duplicates, which (dev, inode) cannot catch.
        for subdir in subdirs {
            guard !isCancelled else { break }
            let subdirPath = appendPathComponent(dirPath, subdir.name)
            switch visited.traversalDecision(
                path: subdirPath,
                dev: subdir.dev,
                inode: subdir.inode
            ) {
            case .traverse:
                break
            case .mountBoundary:
                progress.incrementSkippedMount(path: subdirPath)
                continue
            case .alreadyVisited, .firmlinkDuplicate:
                continue
            }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
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
    /// the populated scratch buffer to `materialize` - the only variation point.
    ///
    /// `materialize` performs bundle-size computation and writes the children into
    /// their destination (tree or deferred arena) in whichever order that destination
    /// requires (immediate mode publishes to the tree first so the UI sees the entry
    /// sooner, then patches bundle sizes in place; deferred mode has no tree node to
    /// patch later, so it must bake bundle sizes into the scratch children before they
    /// are copied into the arena). It returns the first child index, which this shared
    /// core then uses to enqueue subdirectories - identical in both strategies.
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
                if rawEntry.linkCount > 1 {
                    node.hasMultipleHardlinks = true
                }
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
                    scratch.bundleDirs.append((
                        nameOffset: nameOffset,
                        nameLength: nameLength,
                        childIndex: childLocalIndex,
                        dev: rawEntry.device,
                        inode: rawEntry.inode
                    ))
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
            progress.incrementSkippedDirectories(path: dirPath)
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
            let subdirName = Self.nameString(in: scratch.namePool, offset: subdir.nameOffset, length: subdir.nameLength)
            guard !subdirName.isEmpty else { continue }
            let subdirPath = appendPathComponent(dirPath, subdirName)
            switch visited.traversalDecision(
                path: subdirPath,
                dev: subdir.dev,
                inode: subdir.inode
            ) {
            case .traverse:
                break
            case .mountBoundary:
                progress.incrementSkippedMount(path: subdirPath)
                continue
            case .alreadyVisited, .firmlinkDuplicate:
                continue
            }
            let childTreeIndex = firstChildIndex + UInt32(subdir.childIndex)
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

            for bundle in scratch.bundleDirs {
                guard !self.isCancelled else { break }
                let bundleName = Self.nameString(
                    in: scratch.namePool,
                    offset: bundle.nameOffset,
                    length: bundle.nameLength
                )
                guard !bundleName.isEmpty else { continue }
                let bundlePath = appendPathComponent(dirPath, bundleName)
                let bundleTreeIndex = firstChildIndex + UInt32(bundle.childIndex)
                if visited.isMountBoundary(device: bundle.dev) {
                    progress.incrementSkippedMount(path: bundlePath)
                    tree.updateNode(at: bundleTreeIndex) { node in
                        node.isBundle = false
                    }
                    continue
                }
                if self.computeBundleSizes {
                    let (bundleFileSize, bundleAllocatedSize) = filesystem.computeBundleSize(
                        path: bundlePath,
                        isCancelled: { self.isCancelled }
                    )
                    guard bundleFileSize > 0 || bundleAllocatedSize > 0 else { continue }
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
            // No tree node exists yet to patch after the fact - bundle sizes must be
            // baked into the scratch children before they are copied into the arena.
            for bundle in scratch.bundleDirs {
                guard !self.isCancelled else { break }
                let bundleName = Self.nameString(
                    in: scratch.namePool,
                    offset: bundle.nameOffset,
                    length: bundle.nameLength
                )
                guard !bundleName.isEmpty else { continue }
                let bundlePath = appendPathComponent(dirPath, bundleName)
                if visited.isMountBoundary(device: bundle.dev) {
                    progress.incrementSkippedMount(path: bundlePath)
                    scratch.children[bundle.childIndex].node.isBundle = false
                    continue
                }
                if self.computeBundleSizes {
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

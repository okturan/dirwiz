import Foundation
import CoreServices

/// Represents a filesystem change detected by FSEvents.
public struct FSChange: Sendable {
    public let path: String
    public let flags: FSEventStreamEventFlags
    public let timestamp: Date

    public var isCreated: Bool { flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 }
    public var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    public var isModified: Bool { flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    public var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    public var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
}

/// Accumulated change summary for a directory.
public struct DirectoryChangeSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public var changeCount: Int
    public var lastChangeDate: Date
    public var hasCreations: Bool
    public var hasDeletions: Bool
    public var hasModifications: Bool
    /// True once ANY event in the accumulation window reported this directory itself.
    /// False means the path exists only through file→parent reduction and is shallow-
    /// eligible for the next apply (see `JournalReplay.fileOnlyTargets` for why).
    public var hasDirectoryEvent: Bool = false

    public init(
        id: String,
        path: String,
        changeCount: Int,
        lastChangeDate: Date,
        hasCreations: Bool,
        hasDeletions: Bool,
        hasModifications: Bool,
        hasDirectoryEvent: Bool = false
    ) {
        self.id = id
        self.path = path
        self.changeCount = changeCount
        self.lastChangeDate = lastChangeDate
        self.hasCreations = hasCreations
        self.hasDeletions = hasDeletions
        self.hasModifications = hasModifications
        self.hasDirectoryEvent = hasDirectoryEvent
    }
}

/// Monitors filesystem changes using FSEvents after initial scan.
///
/// Uses the low-level C callback FSEvents API, which requires an unmanaged
/// self pointer - hence `@unchecked Sendable`. All mutable state is guarded
/// by `lock`.
public final class FSEventsMonitor: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let watchPath: String
    private let ignoredRoots: [String]
    private let ignoredExactPaths: [String]
    private let ignoredPathPrefixes: [String]
    private let lock = NSLock()
    private var changes: [String: DirectoryChangeSummary] = [:]
    private var isRunning = false
    private var onChanges: (@Sendable ([DirectoryChangeSummary]) -> Void)?

    /// Maximum number of directory entries kept to prevent unbounded growth.
    private static let maxTrackedDirectories = 1000

    private func isIgnoredEventPath(_ path: String) -> Bool {
        for candidate in ignoredExactPaths where path == candidate { return true }
        for prefix in ignoredPathPrefixes where path.hasPrefix(prefix) { return true }
        return false
    }

    /// Swift-native parent derivation: `(path as NSString).deletingLastPathComponent`
    /// bridges to NSString per call, which is measurable at thousands of events per
    /// batch. FSEvents file paths carry no trailing slash, so a plain split is exact.
    static func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        if slash == path.startIndex { return "/" }
        return String(path[path.startIndex..<slash])
    }

    public convenience init(watchPath: String) {
        self.init(watchPath: watchPath, ignoredRoots: [DirWizOwnedPaths.applicationSupportRoot()])
    }

    /// Test seam for proving self-owned persistence cannot feed the living view.
    init(watchPath: String, ignoredRoots: [String]) {
        self.watchPath = watchPath
        self.ignoredRoots = ignoredRoots
        // Pre-canonicalized forms for the per-event hot path. FSEvents emits
        // `/private/var` spellings, so prefix checks against these are exact without
        // per-event NSString canonicalization; the `/var` alias is kept for roots that
        // live under `/private/var` anyway.
        var exact: [String] = []
        var prefixes: [String] = []
        for root in ignoredRoots {
            exact.append(root)
            prefixes.append(root + "/")
            if root.hasPrefix("/private/var/") || root == "/private/var" {
                let alias = String(root.dropFirst("/private".count))
                exact.append(alias)
                prefixes.append(alias + "/")
            }
        }
        self.ignoredExactPaths = exact
        self.ignoredPathPrefixes = prefixes
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start monitoring. Calls `onChanges` on a background thread when changes
    /// are detected. Batches events with a 3-second latency window.
    public func start(onChanges: @escaping @Sendable ([DirectoryChangeSummary]) -> Void) {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        self.onChanges = onChanges
        lock.unlock()

        let pathsToWatch = [watchPath as CFString] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            flags
        ) else { return }

        let queue = DispatchQueue(label: "com.dirwiz.fsevents", qos: .utility)
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)

        lock.lock()
        self.stream = newStream
        isRunning = true
        lock.unlock()
    }

    /// Stop monitoring and release the FSEventStream.
    public func stop() {
        lock.lock()
        let s = stream
        stream = nil
        isRunning = false
        onChanges = nil
        lock.unlock()

        if let s {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// Get current accumulated changes, sorted by changeCount descending.
    public func currentChanges() -> [DirectoryChangeSummary] {
        lock.lock()
        let snapshot = changes.values.sorted { $0.changeCount > $1.changeCount }
        lock.unlock()
        return snapshot
    }

    /// Clear accumulated changes.
    public func clearChanges() {
        lock.lock()
        changes.removeAll()
        lock.unlock()
    }

    /// Whether the monitor is currently running.
    public var monitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    // MARK: - Internal

    /// Process raw FSChange events into directory summaries.
    @discardableResult
    func processChanges(_ newChanges: [FSChange]) -> Bool {
        lock.lock()
        var acceptedChange = false

        for change in newChanges {
            // Hot path: thousands of events arrive per 3-second batch under real churn.
            // The general `DirWizOwnedPaths.contains` canonicalizes with NSString
            // `standardizingPath` per call, which burned ~30% of a core continuously on
            // this queue (sampled live). FSEvents already emits `/private/var` spellings,
            // so a plain prefix check against the pre-canonicalized roots is exact here;
            // `ignoredPathPrefixes` also carries the `/var` alias for belt and braces.
            guard !isIgnoredEventPath(change.path) else { continue }
            acceptedChange = true
            let dirPath = change.isDirectory
                ? change.path
                : Self.parentDirectory(of: change.path)

            if var summary = changes[dirPath] {
                summary.changeCount += 1
                summary.lastChangeDate = change.timestamp
                if change.isCreated { summary.hasCreations = true }
                if change.isRemoved { summary.hasDeletions = true }
                if change.isModified { summary.hasModifications = true }
                if change.isDirectory { summary.hasDirectoryEvent = true }
                changes[dirPath] = summary
            } else {
                changes[dirPath] = DirectoryChangeSummary(
                    id: dirPath,
                    path: dirPath,
                    changeCount: 1,
                    lastChangeDate: change.timestamp,
                    hasCreations: change.isCreated,
                    hasDeletions: change.isRemoved,
                    hasModifications: change.isModified,
                    hasDirectoryEvent: change.isDirectory
                )
            }
        }

        // Self-owned persistence writes must be invisible to LiveRefreshPolicy, not
        // merely absent from the accumulated path list. Re-publishing the old snapshot
        // for an ignored-only batch would still reset the coordinator's quiescence clock
        // and delay a real pending refresh.
        guard acceptedChange else {
            lock.unlock()
            return false
        }

        // Evict lowest-activity entries if we exceed the cap.
        if changes.count > Self.maxTrackedDirectories {
            let sorted = changes.sorted { $0.value.changeCount > $1.value.changeCount }
            changes = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxTrackedDirectories).map { ($0.key, $0.value) })
        }

        let snapshot = changes.values.sorted { $0.changeCount > $1.changeCount }
        let callback = onChanges
        lock.unlock()

        callback?(snapshot)
        return true
    }
}

// MARK: - C Callback

/// Top-level C function used as the FSEventStream callback.
/// Must not capture any context - the monitor reference comes via `clientCallBackInfo`.
private let fsEventsCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in

    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FSEventsMonitor>.fromOpaque(info).takeUnretainedValue()

    guard numEvents > 0 else { return }
    let pathArray = unsafeBitCast(eventPaths, to: CFArray.self)
    guard CFArrayGetCount(pathArray) >= numEvents else { return }

    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    let now = Date()
    var batch: [FSChange] = []
    batch.reserveCapacity(numEvents)

    for i in 0..<numEvents {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, i) else { continue }
        let path = unsafeBitCast(rawPath, to: CFString.self) as String
        batch.append(FSChange(
            path: path,
            flags: flags[i],
            timestamp: now
        ))
    }

    monitor.processChanges(batch)
}
